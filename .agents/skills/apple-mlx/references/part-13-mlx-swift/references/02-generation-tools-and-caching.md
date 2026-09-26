# Generation, tool calling, and KV cache management in Swift

**Part 13 · MLX in Swift · Reference 02**

**Version floor: `mlx-swift-lm` 3.31.4 (released 2026-06-30), plus `main` at commit
`3cbf928b5eb24190e8952725699ae6a3bb02824d` (2026-07-24).** Like mlx-lm in Python, this is a Swift
package rather than an OS framework, so its primary version axis is the *package* version. The
package declares `swift-tools-version: 6.1` and platforms **macOS 14 / iOS 17 / tvOS 17 /
visionOS 1**, and depends on `mlx-swift` `.upToNextMinor(from: "0.31.4")`.

Three OS floors do bite, and they are routinely confused:

- **The core libraries — `MLXLMCommon`, `MLXLLM`, `MLXVLM`, `MLXEmbedders` — run on iOS 17 /
  macOS 14.** Everything in §2 through §9 of this guide is available there.
- **The Foundation Models bridge (`MLXFoundationModels`, `#huggingFaceLanguageModel`) requires
  iOS 27.0 / macOS 27.0 / visionOS 27.0 *and* the 27 SDK.** It is compiled out entirely on the
  26 SDK by `#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`.
- **Apple's own `LLMBasic` sample app declares iOS/macOS 26.2 and Swift 6**; the `Numerical`
  samples in the same repo require 26.5. Those are sample-project floors, not library floors.

> ✅ **VERIFIED** — `Package.swift:1-14` (tools version, platforms), `Package.swift:60-66`
> (mlx-swift pin), `Package.swift:44-59` (the `FoundationModelsIntegration` trait),
> `MLXHuggingFace/FoundationModelsMacros.swift:3` (the SDK gate),
> `Applications/LLMBasic/README.md`. All read from the clone at HEAD `3cbf928`.

---

## What this covers

This is the Swift counterpart to [Part 12 guide 04](../../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md),
and it is deliberately structured to mirror it so you can move between the two languages without
relearning the model. Where an API corresponds, this guide says so and names the Python spelling.
Where it *doesn't* correspond — and there are more of those than you would expect from two ports of
the same design — the difference is called out, because **every one of those gaps has produced a
real bug**.

Five things in depth:

- **§2–§4 — The generation API.** `generate`, `generateTokens`, `generateTask`, `ChatSession`, and
  the `TokenIterator` underneath all of them. `GenerateParameters` field by field, sampler and
  logit-processor selection, and the stream event types. One complete, copyable async streaming
  program with correct cancellation.
- **§5 — Input types.** `UserInput` → `UserInputProcessor` → `LMInput`, `Chat.Message`, and the
  VLM path where images and video become part of the token stream.
- **§6 — Tokenizers and chat templates.** How templates get resolved, and the ⚠️ silent failure
  where a mismatched or absent template produces fluent, degraded output with no error at any
  layer. With a render-and-eyeball recipe you can run in ten seconds.
- **§7 — Tool calling.** **Ten** tool-call wire formats across the supported model families, why
  the variety exists, how the library detects and parses each one, and what to do when your model's
  format is not one of the ten. The variance *is* the lesson.
- **§8–§9 — KV caching.** **Eight** concrete cache types, mapped to their Python counterparts;
  the selection rule; prompt caching to disk; cross-turn reuse; and the two real Swift-side cache
  bugs (`mlx-swift-lm#312` and `#424`) that this guide exists partly to document, because both are
  silent and both destroy output quality rather than crashing.
- **§10 — `MLXEmbedders`**, briefly. A local Swift RAG pipeline wants an embedder *and* an LLM in
  the same process, and the memory interaction between them is not obvious.

## What this does *not* cover

- **Loading models, factories, registries, downloaders, the `MLXHuggingFace` macros.** Named here
  where a signature needs them; taught in Part 13's model-loading guide.
- **Putting an MLX model behind `LanguageModelSession`.** `MLXFoundationModels`,
  `#huggingFaceLanguageModel`, `MLXGuidedGeneration` and the xgrammar-backed structured output
  path are [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md). §7.9 explains only the parts of the
  tool-calling story that leak across that boundary.
- **LoRA / DoRA adapters and training.** `LoRAContainer`, `LoRATrain` — a separate Part 13 guide.
- **Porting a model architecture to Swift.** `attentionWithCacheUpdate` appears in §8.7 because
  cache correctness depends on calling it right, but the porting recipe is elsewhere.
- **Metal kernel behaviour underneath all of this.** Why `head_dim = 72` silently falls back to a
  composed SDPA is [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md); §9.5 gives the one-line
  consequence.

## What you need

- **Apple silicon.** MLX Swift will build for the simulator but you are not measuring anything
  real there.
- **Xcode 26.x is enough** for everything in §2–§10. Xcode 27 (the 27 SDK) is required *only* if
  you want the Foundation Models bridge to compile to something other than an empty library.
- **`swift test` does not work on this package.** Use
  `xcodebuild test -scheme mlx-swift-lm-Package -destination 'platform=macOS' -skipPackagePluginValidation`.
  The flag is mandatory because mlx-swift 0.31.5 added a `CudaBuild` build-tool plugin that
  `xcodebuild` refuses to run non-interactively without it.
  > ✅ **VERIFIED** — `CONTRIBUTING.md:22-55`; rationale from commit `d242429`.
- **`-skipMacroValidation`** on every `xcodebuild` invocation if you consume `MLXHuggingFace`,
  which ships Swift macros.
- A package pin. The repo's own README recommends
  `.package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3"))`.

---

## ⚠️ Read this before you trust a signature below

**The evidence class here is strong but not uniform.** Three tiers appear in this guide:

**Tier 1 — the library source.** Every signature, default, enum case and error string in §2–§10
was read out of `ml-explore/mlx-swift-lm` at HEAD `3cbf928` (2026-07-24) during the research pass
behind this guide. That is the strongest evidence available for this package, because it is the
code that runs.

**Tier 2 — Apple's own sample projects.** `ml-explore/mlx-swift-examples` at HEAD `378f244`
(2026-06-16) contains the `LLMBasic`, `MLXChatExample` and `LLMEval` apps plus the `llm-tool`,
`embedder-tool` CLIs. Where this guide shows an *idiom* — how to cancel, how to time first token,
how to hold a `ModelContainer` — it comes from there, verbatim, because that is compiling
first-party code rather than something a guide author composed.

**Tier 3 — issue threads.** §9's two bug write-ups, and several gotchas, come from the
`ml-explore/mlx-swift-lm` issue tracker. These are community bug reports with maintainer replies.
Where the maintainer (`davidkoski`) spoke, he is quoted and attributed. **Line numbers quoted from
issue bodies drift** — the issue was filed against a commit you are not on. Verify before you rely
on a line number.

⚠️ **Four things that were *not* read, and are therefore not asserted:** the body of
`SpeculativeTokenIterator` (`Evaluate.swift:864-1069`), `MTPSpeculativeTokenIterator.swift`,
`ToolCallProcessor.swift` past line 140, and `TurboQuantKVCache.swift` / `TurboQuantKernels.swift`
(4,132 lines between them). Claims about those files are limited to their public symbols and doc
comments, and are marked. See §11.3.

Markers used throughout:

> ✅ **VERIFIED** — read from the package source, an Apple sample project, or a repository
> document this session. The citation follows: file and line, commit, or issue number.
>
> 🟡 **RECONSTRUCTED** — the concept is attested but the exact spelling, number or ordering is
> inferred from a symbol name or doc comment rather than a body.
>
> 🔴 **GAP** — could not verify. The box says what is unknown, what would resolve it, and what to
> ship in the meantime.
>
> ⚠️ **SILENT FAILURE** — it does not throw. This guide has nine.

---

## Contents

1. [Where the Swift stack sits, and the 3.x break](#1-where-the-swift-stack-sits)
2. [The generation API surface](#2-the-generation-api-surface)
3. [`GenerateParameters`, samplers, and logit processors](#3-generateparameters-samplers-and-logit-processors)
4. [`TokenIterator`: the thing all of it sits on](#4-tokeniterator-the-thing-all-of-it-sits-on)
5. [Input types: `UserInput`, `Chat.Message`, `LMInput`, and the VLM path](#5-input-types)
6. [Tokenizers and chat templates](#6-tokenizers-and-chat-templates)
7. [Tool calling: ten formats and why](#7-tool-calling-ten-formats-and-why)
8. [KV cache: eight types, one contract](#8-kv-cache-eight-types-one-contract)
9. [Two real Swift-side cache bugs](#9-two-real-swift-side-cache-bugs)
10. [`MLXEmbedders`, and what a local RAG pipeline actually needs](#10-mlxembedders)
11. [Decision tables, silent-failure register, gap register](#11-decision-tables-silent-failure-register-gap-register)

---

## 1. Where the Swift stack sits

### 1.1 Two repositories, and which one you actually depend on

If you learned MLX Swift before late 2025 you learned it wrong, in one specific way: the libraries
moved.

> ✅ **VERIFIED** — `mlx-swift-examples/README.md:56-62`, verbatim:
>
> > `MLXLMCommon`, `MLXLLM`, `MLXVLM` and `MLXEmbedders` have moved to a new repository
> > containing _only_ reusable libraries: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
> >
> > Previous URLs and tags will continue to work, but going forward all updates to these
> > libraries will be done in the other repository. Previous tags _are_ supported in
> > the new repository.
>
> The split happened in `mlx-swift-examples` commit `0db7c5d` (2025-11-11, "split out
> mlx-swift-lm (#441)").

So:

| Repo | What is in it now | You depend on it… |
|---|---|---|
| `ml-explore/mlx-swift` | The array framework, `MLXArray`, `MLXNN`, `MLXOptimizers`, `MLXFast`, `Memory`, `WiredMemoryManager` | transitively |
| `ml-explore/mlx-swift-lm` | `MLXLMCommon`, `MLXLLM`, `MLXVLM`, `MLXEmbedders`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration` | **directly — this is the package** |
| `ml-explore/mlx-swift-examples` | Sample apps (`LLMBasic`, `MLXChatExample`, `LLMEval`, `StableDiffusionExample`, `MNISTTrainer`), CLIs (`llm-tool`, `embedder-tool`, `image-tool`), `MLXMNIST`, `StableDiffusion` | as a reference, not a dependency |

The library repo ships **nine products** — `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`,
`MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration`, `BenchmarkHelpers`,
`IntegrationTestHelpers`.

> ✅ **VERIFIED** — `Package.swift:15-43`.

⚠️ **The dead links are real.** `Libraries/MLXLLM/README.md:68` and `Libraries/MLXVLM/README.md:82`
still point at `../../Tools/llm-tool`, which lives in the *other* repository. Several per-library
READMEs and the shipped `skills/` directory reference packages that do not exist —
`swift-huggingface-mlx`, `swift-tokenizers-mlx`, modules `MLXLMHuggingFace`, `MLXLMTokenizers`,
`MLXEmbeddersHuggingFace`. **None of those are in `Package.swift`.** Trust the root `README.md` and
`Documentation.docc/using.md`; treat the per-library READMEs and `skills/*` code snippets as stale.

> ✅ **VERIFIED** — the stale-import problem is stated in the research notes against
> `skills/mlx-swift-lm/SKILL.md`, `Libraries/MLXLMCommon/README.md`, `Libraries/MLXLLM/README.md`,
> `Libraries/MLXVLM/README.md` and `Libraries/MLXEmbedders/README.md`. Confirmed against
> `Package.swift`, which has exactly two dependencies: `mlx-swift` and `swift-syntax`.

### 1.2 The 3.x break: tokenizers and downloading are yours now

`main` is a new major version, and the reason matters for every code sample below.

> ✅ **VERIFIED** — `README.md:1-19`, verbatim:
>
> > The `main` branch is a _new_ major version number: 3.x. In order to decouple from tokenizer
> > and downloader packages some breaking changes were introduced.

In 2.x, mlx-swift-lm depended on `swift-transformers` and `Hub` directly. In 3.x it depends on
**neither**. Instead it declares two protocols and expects you to supply conformers:

```swift prelude:guide-context
public protocol Downloader: Sendable {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

public protocol TokenizerLoader: Sendable {
    func load(from directory: URL) async throws -> any Tokenizer
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Downloader.swift:16-36`,
> `Libraries/MLXLMCommon/TokenizerLoader.swift` (the whole file).

You have two supported ways to satisfy them:

**(a) Hand-roll conformances.** Fine if you already have a download layer, or if you ship weights
in the app bundle and never touch the network. `Downloader` is not used at all when you load from
a local directory.

**(b) Use the `MLXHuggingFace` macros** over `swift-huggingface` + `swift-transformers`. This is
the path Apple's samples take. Seven freestanding expression macros; the two you will use are
`#hubDownloader()` and `#huggingFaceTokenizerLoader()`.

The canonical `Package.swift` fragment, from the root README:

```swift illustrative
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
    .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
],
targets: [
    .target(
        name: "YourTargetName",
        dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
]
```

> ✅ **VERIFIED** — `README.md:63-100`, verbatim.

⚠️ **The macros expand to code that references symbols at your call site.** `#hubDownloader()`
expands to a `struct HubBridge: MLXLMCommon.Downloader` that names `HuggingFace.HubClient`,
`HuggingFace.Repo.ID` and `Foundation.Progress`. If you forget `import HuggingFace` you get
"cannot find type" errors pointing at a line you did not write. The required imports are
documented at `MLXHuggingFace/FoundationModelsMacros.swift:17-25`: `Foundation`,
`MLXHuggingFace`, `MLXFoundationModels`, `MLXLMCommon`, `HuggingFace`, `Tokenizers`.

The 3.x migration diff from Apple's own samples, which is the shortest possible statement of the
break:

```diff
-import Hub
+import HuggingFace
 import MLX
+import MLXHuggingFace

-        let hub =
-            if let download { HubApi(downloadBase: download) } else { HubApi() }
-        return try await modelFactory.loadContainer(hub: hub, configuration: modelConfiguration)
+        return try await modelFactory.loadContainer(
+            from: self.downloader,
+            using: #huggingFaceTokenizerLoader(),
+            configuration: modelConfiguration)
```

> ✅ **VERIFIED** — `mlx-swift-examples` commit `357c97f`, quoted from the research notes.
> The same commit bumped mlx-swift `0.30.3 → 0.31.3` and swift-transformers to
> `.upToNextMajor(from: "1.3.0")`, and added `-skipMacroValidation` to every `xcodebuild`
> invocation in CI.

### 1.3 The four-layer picture, and where you should be working

```
                        ┌──────────────────────────────────────────┐
   easiest, least        │  ChatSession                             │  §2.2
   control               │  respond / streamResponse / streamDetails│
                        └──────────────────┬───────────────────────┘
                                           │
                        ┌──────────────────▼───────────────────────┐
                        │  ModelContainer.generate(input:params:)   │  §2.3
                        │  MLXLMCommon.generate(input:…context:)    │
                        └──────────────────┬───────────────────────┘
                                           │
                        ┌──────────────────▼───────────────────────┐
                        │  generateTask(...) → (stream, Task)       │  §2.4
                        │  generateTokens(...) → AsyncStream<Token> │
                        └──────────────────┬───────────────────────┘
                                           │
   hardest, full         ┌──────────────────▼───────────────────────┐
   control               │  TokenIterator — Sequence<Int>           │  §4
                        │  model.prepare / callAsFunction / cache   │
                        └──────────────────────────────────────────┘
```

**The advice, stated once:** start at `ChatSession`. It handles the chat template, the KV cache
across turns, the tool loop, cancellation and the detokenizer. Drop a layer only when you need
something it does not expose — a cache you own, custom stop logic, per-token telemetry, a
`TokenIteratorProtocol` of your own. Most apps never leave the top two layers. Apple's own
`LLMBasic` sample never leaves the first.

The Python correspondence:

| MLX Swift | mlx-lm (Python) | Note |
|---|---|---|
| `ChatSession` | *no direct equivalent* | Python's closest is `mlx_lm.chat`'s REPL loop, which is a CLI, not an API |
| `MLXLMCommon.generate(input:…) -> AsyncStream<Generation>` | `stream_generate(...)` generator | Swift yields `Generation` cases; Python yields `GenerationResponse` |
| `generateTokens(...) -> AsyncStream<TokenGeneration>` | `generate_step(...)` generator | Swift wraps it; Python is the raw generator |
| `TokenIterator` | `generate_step` | Swift's is a `struct` conforming to `Sequence`/`IteratorProtocol` |
| `GenerateParameters` | scattered kwargs + `make_sampler` / `make_logits_processors` | **Swift bundles what Python splits** — §3.1 |
| `ModelContainer` | *no equivalent* | Python has no concurrency container; a `(model, tokenizer)` tuple is passed around |

That last row is the single biggest structural difference and it is the source of §9's first bug:
**Swift has a concurrency-safe container holding a `ModelContext` struct, and Python has a list and
a tuple.** Value semantics change the answer.

---

## 2. The generation API surface

### 2.1 The matrix

There are five non-deprecated entry points and they differ along three axes: **what the stream
yields**, **whether you get a `Task` handle back**, and **whether the call throws before it
streams**. Get this table into your head and the rest of §2 is detail.

| Function | Yields | Task handle | Throws | Use when |
|---|---|---|---|---|
| `generate(input:cache:parameters:context:wiredMemoryTicket:tools:)` | `AsyncStream<Generation>` | no | ✅ (prefill) | one-shot text generation |
| `generateTokens(input:cache:parameters:context:includeStopToken:wiredMemoryTicket:)` | `AsyncStream<TokenGeneration>` | no | ✅ | you want raw token IDs |
| `generateTask(promptTokenCount:modelConfiguration:tokenizer:iterator:wiredMemoryTicket:tools:)` | `(AsyncStream<Generation>, Task<Void, Never>)` | ✅ | no — you built the iterator | you must observe completion |
| `generateTokensTask(input:cache:parameters:context:includeStopToken:wiredMemoryTicket:)` | `(AsyncStream<TokenGeneration>, Task<Void, Never>)` | ✅ | ✅ | raw tokens **and** completion |
| `generateTokenTask(promptTokenCount:modelConfiguration:tokenizer:iterator:includeStopToken:wiredMemoryTicket:)` | `(AsyncStream<TokenGeneration>, Task<Void, Never>)` | ✅ | no | custom iterator, raw tokens |

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Evaluate.swift`, non-deprecated `generate*` overloads.
> The `…Task` variants take a `consuming TOKEN: TokenIteratorProtocol` rather than an `LMInput`,
> which is *why* they cannot throw: the throwing part (prefill) already happened when you
> constructed the iterator. See §4.2.

Plus two speculative-decoding variants of each of the first two, taking either a `draftModel:` or
an `mtpDrafter:` — §2.6.

**Why the throwing/non-throwing split matters.** `try generate(...)` can throw *before* returning
the stream, because prefill runs inside `TokenIterator.init`. Once you hold the `AsyncStream`,
iteration is non-throwing — a failure mid-generation ends the stream rather than throwing at the
`for await`. That is the opposite of `ChatSession.streamResponse(to:)`, which returns an
`AsyncThrowingStream<String, Error>` and *does* throw at the `for try await`. Two adjacent APIs,
two error models.

### 2.2 `ChatSession` — the layer you should start at

```swift prelude:guide-context
public final class ChatSession {
    public var instructions: String?
    public var processing: UserInput.Processing
    public var generateParameters: GenerateParameters
    public var additionalContext: [String: any Sendable]?
    public var tools: [ToolSpec]?
    public var toolDispatch: (@Sendable (ToolCall) async throws -> String)?
    public let speculativeDecoding: SpeculativeDecodingConfig?
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/ChatSession.swift` (919 lines).

Eight initializers: `{ModelContainer, ModelContext}` × `{plain, history: [Chat.Message],
cache: [KVCache]}`, all sharing this tail of defaults:

```swift illustrative
instructions: String? = nil,
speculativeDecoding: SpeculativeDecodingConfig? = nil,
generateParameters: GenerateParameters = .init(),
processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512)),
additionalContext: [String: any Sendable]? = nil,
tools: [ToolSpec]? = nil,
toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil
```

> ✅ **VERIFIED** — `ChatSession.swift`, initializer defaults.

⚠️ **Note the default `processing`: images are resized to 512×512 unless you say otherwise.** For
a document-understanding VLM that is often too small to read text in the image and there is no
warning. Apple's `MLXChatExample` overrides it to 1024×1024 on its raw-`UserInput` path.

The public methods:

```swift illustrative
func respond(to prompt: String, role: Chat.Message.Role = .user,
             images: consuming [UserInput.Image], videos: …, audios: …) async throws -> String
func respond(to prompt: String, role: … = .user, image: UserInput.Image? = nil,
             video: … = nil, audio: … = nil) async throws -> String
func respond(to messages: consuming [Chat.Message]) async throws -> String

func streamResponse(to prompt: String, role: … = .user,
                    images: … = [], videos: … = [], audios: … = [])
    -> AsyncThrowingStream<String, Error>
func streamResponse(to messages: consuming [Chat.Message]) -> AsyncThrowingStream<String, Error>

func streamDetails(to prompt: String, role: … = .user,
                   images: … = [], videos: … = [], audios: … = [])
    -> AsyncThrowingStream<Generation, Error>
func streamDetails(to messages: consuming [Chat.Message]) -> AsyncThrowingStream<Generation, Error>

func clear() async                          // reset cache to .empty, keep instructions
func synchronize() async                    // wait for exclusive access to the KVCache
func saveCache(to url: URL) async throws     // throws ChatSessionError.noCacheAvailable
```

> ✅ **VERIFIED** — `ChatSession.swift` public surface.

**`streamResponse` yields `String` deltas; `streamDetails` yields `Generation` cases.** If you want
tokens-per-second, tool calls, or a stop reason, you want `streamDetails`. If you want to append
text to a label, `streamResponse` is enough. Apple's `LLMBasic` uses the first, `llm-tool eval`
uses the second.

⚠️ **`ChatSession` is not thread-safe.** The source says so plainly: *"Each session should be used
from a single task/thread at a time."* `ModelContainer` **is** — that is the whole point of it —
and the session is deliberately built so that multiple distinct `ChatSession`s can run
concurrently against the same weights. The model is pulled *out* of the container via a
`SendableBox`, because as the source puts it, *"the KVCache cannot be shared and that is the lock
that is held here."*

> ✅ **VERIFIED** — `ChatSession.swift` doc comment and `streamMap` implementation
> (`ChatSession.swift:574-836`).

### 2.3 `ModelContainer.generate` and the free function

Two spellings of the same thing:

```swift illustrative
// on the container — convenience, takes the lock for you
public func generate(input: consuming sending LMInput,
                     parameters: GenerateParameters,
                     wiredMemoryTicket: WiredMemoryTicket? = nil) async throws
    -> AsyncStream<Generation>

// free function in MLXLMCommon — you already hold a ModelContext
public func generate(input: LMInput, cache: [KVCache]? = nil,
                     parameters: GenerateParameters,
                     context: ModelContext,
                     wiredMemoryTicket: WiredMemoryTicket? = nil,
                     tools: [[String: any Sendable]]? = nil) throws -> AsyncStream<Generation>
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/ModelContainer.swift:145-229` and
> `Libraries/MLXLMCommon/Evaluate.swift`.

Note the asymmetry: **the container convenience does not take a `cache:` or `tools:`.** If you want
to supply your own KV cache or pass tool schemas, you must go through the free function inside
`perform`. Apple's `MLXChatExample` does exactly that:

```swift illustrative
return try await modelContainer.perform { (context: ModelContext) in
    let lmInput = try await context.processor.prepare(input: userInput)
    let parameters = GenerateParameters(temperature: 0.7)

    return try MLXLMCommon.generate(
        input: lmInput, parameters: parameters, context: context)
}
```

> ✅ **VERIFIED** — `mlx-swift-examples/Applications/MLXChatExample/Services/MLXService.swift`,
> verbatim.

Read that carefully, because it encodes a concurrency rule that is easy to get wrong: **the stream
is *constructed* inside `perform` and *consumed* outside it.** The container's own doc comment
explains why this is safe:

> ✅ **VERIFIED** — `ModelContainer.swift:191-197`, verbatim:
>
> > "Note: this is only visiting the model exclusively for the pre-fill time. Beyond that there is
> > no shared mutable state. This means that there may be concurrent access to the model weights
> > themselves (but they are already evaluated)."

`ModelContainer`'s access methods, in full:

```swift illustrative
public func perform<R: Sendable>(_ action: @Sendable (ModelContext) async throws -> sending R)
    async rethrows -> sending R
public func perform<V: Sendable, R: Sendable>(values: V,
    _ action: @Sendable (ModelContext, V) async throws -> R) async rethrows -> sending R
public func perform<V, R: Sendable>(nonSendable values: consuming V,
    _ action: @Sendable (ModelContext, V) async throws -> R) async rethrows -> sending R
public func update(_ action: @Sendable (inout ModelContext) -> Void) async
```

Plus conveniences: `prepare(input:) -> LMInput`, `decode(tokenIds:) -> String`,
`encode(_:) -> [Int]`, and async computed properties `configuration`, `processor`, `tokenizer`,
`modelDirectory` (throws), `tokenizerDirectory` (throws).

> ✅ **VERIFIED** — `ModelContainer.swift:32-229`.

The **deprecated** forms you will find in older tutorials: `perform { (model, tokenizer) in }`,
`perform(values:) { (model, tokenizer, v) in }`, `decode(tokens:)`, and
`applyChatTemplate(messages:)` on the container. All still compile; all warn.

⚠️ **`MLXArray` is not `Sendable`.** Every `perform` doc comment says callers must `eval()` before
returning an array across the isolation boundary. This is not pedantry — the underlying
`MLXArray` is lazily evaluated, so returning an unevaluated array hands another isolation domain a
promise that will be forced on the wrong thread. And **MLX arrays are thread-affine**: an array
constructed on a worker thread crashes the first time the engine thread touches it.

> ✅ **VERIFIED** — `ModelContainer.swift` doc comments; the thread-affinity statement is quoted
> from mlx-lm PR #1588's body (*"MLX arrays are thread-affine, so building one on a worker thread
> crashes the first time the engine thread touches it"*) — a Python-side finding that applies to
> the same C++ core.

### 2.4 `generateTask` and why early `break` is a trap

The doc comment on the stream-returning `generate` is one of the most load-bearing sentences in
the package:

> ✅ **VERIFIED** — `Evaluate.swift:1425-1429`, verbatim:
>
> > "if the stream is terminated early (e.g. break from the loop) computation will continue using
> > the model, parameters, KVCache, etc. for some time (typically a few ms). This is typically OK
> > for one-shot calls, but for 'chat session' type calls consider using `generateTask(...)` so
> > that the end of the generation task can be observed."

So: `break` out of `for await generation in stream` and the GPU keeps going for a few milliseconds
against a KV cache you are about to reuse. For a one-shot that is harmless. For a chat loop it is a
race. The fix is the `…Task` variants:

```swift prelude:guide-context
let (stream, task) = generateTask(
    promptTokenCount: promptTokenCount,
    modelConfiguration: context.configuration,
    tokenizer: context.tokenizer,
    iterator: iterator)

for await item in stream {
    if shouldStop(item) { break }
}
task.cancel()
await task.value          // ← now the cache is genuinely quiescent
```

`ChatSession` does exactly this internally: `genTask.cancel()` when the consumer terminates or the
enclosing task is cancelled, then `await genTask.value`.

> ✅ **VERIFIED** — `ChatSession.swift` `streamMap`; commit `2c1dd13` explains the deadlock this
> ordering fixes.

### 2.5 The stream event types

```swift illustrative
public enum Generation: Sendable {
    case chunk(String)
    case info(GenerateCompletionInfo)
    case toolCall(ToolCall)

    public var chunk: String?
    public var info: GenerateCompletionInfo?
    public var toolCall: ToolCall?

    @Sendable public static func collect(_ batch: [Generation]?, _ element: Generation)
        -> [Generation]
}

public enum TokenGeneration: Sendable {
    case token(Int)
    case info(GenerateCompletionInfo)
    public var token: Int?
    public var info: GenerateCompletionInfo?
    @Sendable public static func collect(…) -> [TokenGeneration]
}

public enum GenerateStopReason: Sendable { case stop; case length; case cancelled }

public struct GenerateCompletionInfo: Sendable {
    public let promptTokenCount: Int
    public let generationTokenCount: Int
    public let promptTime: TimeInterval
    public let generateTime: TimeInterval
    public let stopReason: GenerateStopReason
    public let proposedDraftTokens: Int?              // MTP only
    public let acceptedDraftTokens: Int?              // MTP only
    public let passthroughReason: String?             // MTP sticky passthrough
    public let speculativeDecodingTelemetry: SpeculativeDecodingTelemetry?
    public var promptTokensPerSecond: Double
    public var tokensPerSecond: Double
    public func summary() -> String
}
```

> ✅ **VERIFIED** — `Evaluate.swift`; the three `Generation` cases are independently confirmed by
> `mlx-swift-examples/Applications/MLXChatExample/ViewModels/ChatViewModel.swift`, which switches
> over all three.

Both `collect` statics exist for one purpose, documented in source as *"Reducer that can be used
with `throttle()` to gather elements into a batch"* — i.e. they are shaped for
`swift-async-algorithms`' `throttle(for:reducing:)`, so a SwiftUI view can coalesce a 200 tok/s
stream into 20 UI updates per second without dropping content.

⚠️ **SILENT FAILURE #1 — the first element of the stream can be a `.toolCall`, and a
"spinner until first text" UI hangs forever.** When a model responds to a tool-enabled prompt by
emitting *only* a tool call, the stream yields `.toolCall` and then `.info` — **zero `.chunk`
events**. A view model that flips `isLoading = false` on the first `.chunk` never flips it.

> ✅ **VERIFIED** — the shape is visible in `mlx-swift-examples/Applications/LLMEval/ViewModels/
> LLMEvaluator.swift:227-352`, which explicitly checks `first.toolCall` *before* `first.chunk` on
> the first element and only enters the chunk loop `if pendingToolCall == nil`. Apple's sample
> handles it; a naive port will not.
>
> **Safe default:** switch exhaustively over `Generation` and drive UI state from `.info`
> (which always arrives last) or from stream termination, never from "first `.chunk`".

The same defect exists on the Foundation Models side of the stack and is recorded independently in
this series' corrections register (C9 item *o*, from Apple's `CoachModel.swift:67-72`). Two
different frameworks, same trap.

### 2.6 Speculative decoding, in one page

Two mechanisms, both exposed as extra `generate` overloads:

```swift illustrative
// draft model: a small model proposes, the big model verifies
public func generate(input:cache:parameters:context:
                     draftModel: any LanguageModel,
                     draftCache: [KVCache]? = nil,
                     numDraftTokens: Int = 2,
                     wiredMemoryTicket:) throws -> AsyncStream<Generation>

// MTP: the model's own multi-token-prediction head proposes
public func generate(input:cache:parameters:context:
                     mtpDrafter: any MTPDrafterModel,
                     blockSize: Int = 4,
                     wiredMemoryTicket:) throws -> AsyncStream<Generation>
```

> ✅ **VERIFIED** — `Evaluate.swift`.

Or, at the `ChatSession` layer, `SpeculativeDecodingConfig`:

```swift illustrative
public init(draftModel: ModelContainer, numDraftTokens: Int = 5,
            memoryPolicy: SpeculativeDecodingMemoryPolicy? = nil)

public init(draftModelBytes: Int, numDraftTokens: Int = 5,
            memoryPolicy: SpeculativeDecodingMemoryPolicy? = nil,
            loadDraftModel: @escaping @Sendable () async throws -> ModelContainer)
```

⚠️ **The default `numDraftTokens` differs between the two doors: 5 in `SpeculativeDecodingConfig`,
2 in the free `generate(…draftModel:…)` function.** If you move a working configuration from one to
the other and the acceptance economics change, that is why.

> ✅ **VERIFIED** — `ChatSession.swift:43-122` vs `Evaluate.swift`.

Memory gating is explicit, which is unusual and welcome:

```swift illustrative
public enum SpeculativeDecodingMemoryAction: Sendable, Hashable {
    case allow, fallbackToDefault, fail
}

public struct SpeculativeDecodingMemoryPolicy: Sendable, Hashable {
    public init(limitBytes: Int? = nil, additionalBytes: Int = 0,
                action: SpeculativeDecodingMemoryAction = .fallbackToDefault)
    public static var recommendedWorkingSet: Self     // GPU.maxRecommendedWorkingSetBytes()
    public func evaluate(mainModelBytes: Int, draftModelBytes: Int)
        -> SpeculativeDecodingMemoryEvaluation
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/SpeculativeDecoding.swift`. `modelWeightBytes(_:)` is
> `model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }`.

Telemetry, if you want to know whether it is paying: `SpeculativeDecodingTelemetry` carries
`roundCount`, `draftTokenCount`, `acceptedDraftTokenCount`, `targetModelCallCount`,
`draftModelCallCount`, `targetVerifiedTokenCount`, `emittedTokenCount`, plus derived
`rejectedDraftTokenCount`, `acceptanceRate`, `meanAcceptedDraftTokensPerRound`,
`meanEmittedTokensPerTargetCall`.

**The two hard constraints, stated once:**

1. **Both models must share the same tokenizer.** `SpeculativeTokenIterator` is a port of
   Python's `speculative_generate_step()` and inherits the requirement.
2. **The KV cache must be trimmable** — which rules out every hybrid / linear-attention model, and
   rules out sliding-window models *after the window wraps*. That second half is §9.2, and it is a
   bug, not a design.

⚠️ **MTP drafters require a manual registration step and fail silently without it.**
`MTPDrafterTypeRegistry.shared` is **empty at bootstrap**; you must
`await Gemma4AssistantRegistration.register()` before loading a Gemma 4 drafter. The stated reason
is a dependency cycle: *"the drafter implementation (`Gemma4AssistantDraftModel`) lives in MLXVLM,
and importing it into MLXLMCommon's `MTPDrafterTypeRegistry.shared` would form a circular
dependency."*

> ✅ **VERIFIED** — `Libraries/MLXVLM/Gemma4AssistantRegistration.swift`, comment verbatim.
> A closely related silent failure is recorded in mlx-swift-lm PR #415: when the
> `mtpEmitFlagKey` opt-in is discarded by a protocol-extension default, *"the target never emits
> drafter state — the MTP iterator **silently falls back to single-token passthrough** (no error,
> just no speedup)."*

---

## 3. `GenerateParameters`, samplers, and logit processors

### 3.1 Every field, with its default

Swift bundles into one struct what Python splits across `generate_step` kwargs, `make_sampler` and
`make_logits_processors`. That is a genuine ergonomic win and one real hazard: **the Swift defaults
are not the Python defaults**, and the most important one is temperature.

```swift illustrative
public init(
    maxTokens: Int? = nil, maxKVSize: Int? = nil, kvBits: Int? = nil,
    kvGroupSize: Int = 64, quantizedKVStart: Int = 0, kvScheme: String? = nil,
    temperature: Float = 0.6, topP: Float = 1.0, topK: Int = 0, minP: Float = 0.0,
    repetitionPenalty: Float? = nil, repetitionContextSize: Int = 20,
    presencePenalty: Float? = nil, presenceContextSize: Int = 20,
    frequencyPenalty: Float? = nil, frequencyContextSize: Int = 20,
    prefillStepSize: Int? = nil, seed: UInt64? = nil
)
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Evaluate.swift:54-169`. All stored properties are
> `public var`, so you can mutate a parameters value after construction — `ChatSession`'s
> `generateParameters` property is designed for that, and `llm-tool chat` exposes it as
> `/temperature`, `/topP`, `/maxTokens` slash commands.

| Property | Type | Default | Notes |
|---|---|---|---|
| `prefillStepSize` | `Int?` | `nil` | `nil` ⇒ the model picks; the generic default is 512 |
| `maxTokens` | `Int?` | `nil` | `nil` ⇒ **unlimited** |
| `maxKVSize` | `Int?` | `nil` | non-nil switches every layer to `RotatingKVCache` |
| `kvBits` | `Int?` | `nil` | affine KV-quantization bit width |
| `kvGroupSize` | `Int` | `64` | |
| `quantizedKVStart` | `Int` | `0` | token offset at which quantization kicks in |
| `kvScheme` | `String?` | `nil` | **overrides `kvBits`**; see §8.5 |
| `temperature` | `Float` | **`0.6`** | `0` ⇒ `ArgMaxSampler` (greedy) |
| `topP` | `Float` | `1.0` | active only when `0 < topP < 1` |
| `topK` | `Int` | `0` | `0` disables |
| `minP` | `Float` | `0.0` | `0` disables |
| `seed` | `UInt64?` | `nil` | reproducible sampling; **inert at `temperature == 0`** |
| `repetitionPenalty` | `Float?` | `nil` | |
| `repetitionContextSize` | `Int` | `20` | |
| `presencePenalty` | `Float?` | `nil` | |
| `presenceContextSize` | `Int` | `20` | |
| `frequencyPenalty` | `Float?` | `nil` | |
| `frequencyContextSize` | `Int` | `20` | |

⚠️ **`temperature` defaults to `0.6`, not `0`.** In Python, `mlx_lm.make_sampler`'s `temp`
defaults to `0.0` — greedy. In Swift the default is sampled. If you are comparing Swift and Python
output for a port, or writing a test that expects determinism, **you must pass
`temperature: 0` explicitly**. This is the single most common source of "the Swift port gives
different answers" reports that are not bugs.

> ✅ **VERIFIED** — Swift default from `Evaluate.swift:54-169`; Python default from
> `mlx_lm/sample_utils.py`'s `make_sampler(temp: float = 0.0, …)`.

⚠️ **`seed` is inert at `temperature == 0`.** Greedy decoding does not consult the RNG, so setting
a seed and getting identical output tells you nothing about reproducibility. And note the
initializer's parameter order: **`prefillStepSize` and `seed` are last**, after all the penalties.
If you are writing a positional call (don't), that will bite.

⚠️ **`maxTokens: nil` means unlimited.** `llm-tool chat` uses this deliberately — `/maxTokens` with
no argument parses to `nil` and removes the limit. In an app, an unlimited budget plus a model that
has entered a repetition loop is an unbounded memory and battery event. Set a ceiling.

The integration-test defaults, if you want a sane starting point that the maintainers actually run:
`GenerateParameters(maxTokens: 200, temperature: 0)`, and `maxTokens: 3000, temperature: 0` for the
long-coherence test.

> ✅ **VERIFIED** — `Libraries/IntegrationTestHelpers/IntegrationTestHelpers.swift`.

### 3.2 How a sampler gets chosen

You never construct a sampler directly unless you want to. `GenerateParameters.sampler()` picks:

```
temperature == 0                     →  ArgMaxSampler()
any of topP/topK/minP active         →  TopPSampler(temperature:topP:topK:minP:seed:)
otherwise                            →  CategoricalSampler(temperature:seed:)
```

> ✅ **VERIFIED** — `Evaluate.swift:171-184`.

The protocols are two lines each:

```swift prelude:guide-context
public protocol LogitSampler {
    func sample(logits: MLXArray) -> MLXArray
}

public protocol LogitProcessor {
    mutating func prompt(_ prompt: MLXArray)
    func process(logits: MLXArray) -> MLXArray
    mutating func didSample(token: MLXArray)
}
```

> ✅ **VERIFIED** — `Evaluate.swift`.

**`TopPSampler` applies its filters in Python mlx-lm's order: `top_p` → `min_p` → `top_k`.** This
is a deliberate port decision and it matters, because the operations do not commute: applying
`top_k` first and then `top_p` gives a different candidate set than the reverse. Masking is done
with `-inf` **in original vocabulary order** (so token identities are preserved), bfloat16 logits
are upcast to float32 before the softmax, and the whole thing runs inside
`withRandomState(randomState)` so a seeded sampler is genuinely reproducible within a process.

`applyTopK` is worth knowing about because it is the reason top-k is cheap here:
`argPartition(-logprobs, kth: topK - 1, axis: -1)[0..., topK...]` followed by `putAlong` — **O(V),
no full sort.** A naive implementation sorts the whole 150k-entry vocabulary every token.

> ✅ **VERIFIED** — `Evaluate.swift:245-327`.

### 3.3 Penalty processors and the GPU-resident ring buffer

`GenerateParameters.processor()` returns `nil` unless at least one penalty is set **and** its
context size is greater than zero; otherwise it returns a
`PenaltyProcessor(repetitionContext:presenceContext:frequencyContext:)`.

The public processor types are `RepetitionContext`, `PresencePenaltyContext`,
`FrequencyPenaltyContext` and the composite `PenaltyProcessor`.

The implementation detail worth internalising: all three share a `TokenRing`, **a GPU-resident ring
buffer built out of `MLX.where` masks**, specifically so that no CPU↔GPU synchronisation happens
per token.

> ✅ **VERIFIED** — `Evaluate.swift:348-400`.

This is not a micro-optimisation. Every generation step calls `asyncEval` to pipeline the next GPU
evaluation; a single `.item()` read on the CPU side collapses that pipeline and serialises the
loop. A repetition-penalty implementation that keeps its window in a Swift `Array` and copies it to
the GPU each step will measurably halve your decode rate. If you write a custom `LogitProcessor`,
**keep its state in `MLXArray`s and never call `.item()`**.

⚠️ **SILENT FAILURE #2 — sampler parameters that do nothing.** `topP` is active only when
`0 < topP < 1`; `topK` is disabled at `0`; `minP` is disabled at `0.0`. Setting `topP: 1.0`
(the default) or `topK: 0` looks like a configuration and is a no-op. Worse, at
`temperature: 0` **every one of them is ignored**, because `ArgMaxSampler` never consults them.
A config file that sets `temperature: 0, topP: 0.9, topK: 40` is greedy decoding with three
decorative fields, and nothing warns.

> **Cheap check:** run the same prompt twice with the same parameters and no seed. Identical output
> ⇒ you are greedy, whatever your `topP` says. Different output ⇒ you are sampling.

### 3.4 Determinism, and what you cannot have

Set `temperature: 0` and you get deterministic output **on one machine, in one process, against
one mlx-swift build**. You do not get:

- **Cross-device bit reproducibility.** Community-measured (`mlx-lm#1280`, 2026-07 research pass):
  the same model (`mlx-community/Qwen3.6-35B-A3B-4bit`), same prompt, `temperature: 0`, same seed,
  same `max_tokens` produced **different generated-token counts on M5 Max versus M3 Ultra** (7857
  vs 6145 tokens on one AIME25 case, both reaching the correct answer). Attribute as
  community-measured, two machines, mlx 0.32.x, July 2026. **Cross-device bit reproducibility is
  not a property MLX offers.**
- **Batch-versus-single equivalence on M5-class hardware.** Also community-measured
  (`mlx#3897`, M5 base `applegpu_g17g`, 32 GB, macOS 26.5.2): `mlx-lm`'s own
  `test_generate.py` fails 8 of 28 tests on `mx.allclose(batch_logprobs, single_logprobs)` at
  `rtol=1e-5`, with max |Δlogprob| ≈ 0.031–0.039. Two independent gen-17 mechanisms were separated
  in that thread — a NAX attention-kernel divergence in fp16/bf16, and TF32 in fp32 GEMM. **A
  strict `rtol=1e-5` batch-equivalence assertion cannot hold on gen-17, in any dtype.**
- **Speculative decoding that is bit-identical to sequential decoding.** "Lossless" holds only up
  to floating-point tie-breaks: three independent reproductions found exact bit-level ties in
  bfloat16 (e.g. two candidates at logit `33.75`, softmax `0.3828`, `logit_gap = 0.0` exactly),
  where batched verify and sequential decode break the tie differently. This is expected
  float non-associativity, not a bug; the resolution upstream was a docstring
  (`mlx-lm` PR #1592), not a code change.

> All three: community-measured, from the July 2026 issue-mining pass over `ml-explore/mlx` and
> `ml-explore/mlx-lm`. Hardware and OS as stated per bullet. Not Apple-published.

**The falsifier recipe, if you suspect a real speculative-decoding bug rather than a tie:** at the
divergence index, replay through the plain sequential path and print both candidates' raw logits,
probabilities and ranks. Gap ≈ 0.0 with both at top rank ⇒ benign tie. Materially non-zero gap with
a dominant baseline token ⇒ a real accept/verify defect worth filing.

---

## 4. `TokenIterator`: the thing all of it sits on

### 4.1 The protocol

```swift illustrative
public protocol TokenIteratorProtocol: Sequence, IteratorProtocol where Element == Int {
    var maxTokens: Int? { get }
    var tokenCount: Int { get }
    var promptPrefillTime: TimeInterval { get }
    var speculativeDecodingTelemetry: SpeculativeDecodingTelemetry? { get }   // default nil
    mutating func discardGeneratedToken()                                     // default no-op
}
```

> ✅ **VERIFIED** — `Evaluate.swift`.

Four conformers ship: `TokenIterator`, `SpeculativeTokenIterator`,
`MTPSpeculativeTokenIterator`, and whatever you write. The `…Task` generation entry points are
generic over `TOKEN: TokenIteratorProtocol`, which is the extension point: if you want n-gram
self-speculation, or a constrained decoder, or a "stop when the JSON closes" iterator, you conform
to this protocol and hand it to `generateTask`.

`discardGeneratedToken()` exists for one reason: when the loop sees a stop token and
`includeStopToken == false`, it needs to tell the iterator *"un-count that."* The default is a
no-op, which is correct for simple iterators and wrong for anything maintaining a transcript.

### 4.2 Three initializers, and the one that costs money

```swift illustrative
@available(*, deprecated, message: "please use init(input:model:cache:parameters:)")
public init(prompt: MLXArray, model: any LanguageModel, cache: [KVCache]? = nil,
            parameters: GenerateParameters) throws

public init(input: LMInput, model: any LanguageModel, cache: [KVCache]? = nil,
            state: LMOutput.State? = nil, parameters: GenerateParameters) throws

public init(input: LMInput, model: any LanguageModel, cache: [KVCache]? = nil,
            state: LMOutput.State? = nil,
            processor: LogitProcessor?, sampler: LogitSampler,
            prefillStepSize: Int? = nil, maxTokens: Int? = nil) throws
```

> ✅ **VERIFIED** — `Evaluate.swift`.

⚠️ **Prefill runs inside `init`.** The body is
`self.promptPrefillTime = try measure { try prepare(...) }`. Constructing a `TokenIterator` is
the expensive, throwing part; iterating it is the cheap part. Two consequences:

1. **Your TTFT clock starts before `init`, not before the first `next()`.** If you time
   `for await` you are measuring decode, not time-to-first-token.
2. **`try` on the constructor is where prefill failures surface** — OOM, an unsupported shape, a
   cancelled task. The stream itself does not throw.

⚠️ **The third initializer explicitly disables cache quantization.** Its source comment is
*"No cache quantization for this direct initialization."* If you drop to the sampler/processor
initializer to get custom sampling, you silently lose `kvBits` / `kvScheme` handling. That is a
correct-by-construction choice on the library's part — those parameters live on
`GenerateParameters`, which this initializer does not take — but it will surprise you if you moved
down a layer to get one feature and lost another.

> ✅ **VERIFIED** — source comment quoted from `Evaluate.swift`.

### 4.3 `state`, and the M-RoPE trap

```swift prelude:guide-context
public internal(set) var state: LMOutput.State?
```

`LMOutput.State` is a heterogeneous typed dictionary:

```swift illustrative
public struct LMOutput {
    public let logits: MLXArray
    public let state: State?
    public struct Key<T>: Identifiable, Sendable { public let id: String }
    public struct State { public subscript<T>(_ key: Key<T>) -> T? { get set } }
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/LanguageModel.swift`.

It carries whatever a model needs to remember across a turn that is not KV. For Qwen VLMs that is
the M-RoPE `positionIds` / `ropeDeltas`. For MTP it is
`mtpLastHiddenStatesKey`, `mtpSharedKVStatesKey`, `mtpEmitFlagKey`.

**The pattern is: seed it in, read it back out.** `ChatSession` does exactly this:

```swift prelude:guide-context
let iterator = try TokenIterator(input: input, model: model, cache: cache,
                                 state: lmState, parameters: parameters)
// … generate …
lmState = iterator.state
```

> ✅ **VERIFIED** — `ChatSession.swift:574-836`.

⚠️ **SILENT FAILURE #3 — dropping `LMOutput.State` between turns produces drifted positions in
VLMs, with no error.** Three linked issues document this:

- **`mlx-swift-lm#419` (fixed, merged)** — prefill's `LMOutput.State` was dropped on
  `TokenIterator`'s `.logits` path. The one-line fix (`self.state = result.state` in the
  `.logits` branch of `prepare`) landed as commit `42f08a8`.
- **`mlx-swift-lm#420` (closed completed 2026-08-28)** — M-RoPE state dropped **across `ChatSession` turns**:
  *"`LMOutput.State` (which carries the M-RoPE `positionIds`/`ropeDeltas` since #239/#283) dies
  with each turn's `TokenIterator`. On the next turn the Qwen VLM position branches see a warm
  cache with no rope deltas and recompute positions from zero."* Fixed for Qwen3.5/3.6 by PR #399
  (**merged 2026-07-14**); PR #448 wiring Qwen2.5-VL / Qwen2-VL **merged 2026-07-30**. **Qwen3-VL
  remained unwired in the researched snapshot** — the issue title named Qwen2.5-VL / Qwen3-VL;
  verify the closing implementation before removing the workaround.
- **`mlx-swift-lm#443` (closed 2026-08-10)** — `savePromptCache` / `loadPromptCache` drop
  `LMOutput.State` entirely in the researched snapshot:
  *"The safetensors layout has no slot for it, `loadPromptCache` returns only
  `([KVCache], metadata)`, and both cache-accepting `ChatSession` initializers hard-code
  `state: nil`."*

The magnitude, quantified in PR #399: on a tiny random-weight model, warm turn-2 logits diverged
from a cold full prefill by **0.43 max-abs**, against an **8.3e-07** decode-path noise floor.
*"At temp 0 on dense grounding prompts this can flip bbox output silently."*

> ✅ **VERIFIED** — issue and PR text from the July 2026 issue-mining pass over
> `ml-explore/mlx-swift-lm`. States re-checked via `gh` **2026-09-04**: issue #420 closed completed
> 2026-08-28 after PR #448 wired Qwen2.5-VL/Qwen2-VL and PR #475 wired Qwen3-VL; #443 closed
> 2026-08-10; PR #399 merged 2026-07-14. Re-check the
> released version you ship before relying on this.
>
> **Safe default for VLMs today:** if you are doing multi-turn grounding (bounding boxes,
> coordinates, "the thing on the left"), verify that your released version contains the #448/#475
> family wiring and #443 fix before restoring a saved KV cache; otherwise prefer re-prefilling.
> Qwen3-VL warm reuse therefore inherits that released-version gate end to end.
> Text-only
> models are unaffected — they carry no state in `LMOutput.State`.

### 4.4 What `next()` actually does

Three behaviours in the body are worth knowing because each one is a hard-won fix:

**Everything is wrapped in `autoreleasepool`.** Source comment: *"a full model forward produces
hundreds of autoreleased wrapper objects … without this, long generations grow host memory without
bound."*

**`asyncEval([token] + cache.flatMap { $0.state })`** — the cache state is evaluated *together
with* the token. This is the Swift equivalent of the Python finding that a functional
(concatenate / slice-assign) cache leaks one Metal buffer per layer per step unless you
`mx.eval` the cache state each step. On the Python side that leak exhausts the **499,000 live-buffer
resource limit** after roughly 11,300 generated tokens on a 43-layer model
(`mlx-lm#1332`, community-measured). Swift does the eval for you — as long as you use the shipped
iterator.

**`if tokenCount % 256 == 0 { MLX.Memory.clearCache() }`** — source comment: *"Matches mlx-lm's
clear cadence."*

> ✅ **VERIFIED** — `Evaluate.swift:757-791`, comments verbatim.

`step(previous:)` wraps the model call in
`withPreparedCache(cache, lengths: previous.sequenceLengths)` and then calls
`maybeQuantizeKVCache(cache:&cache, kvBits:kvGroupSize:quantizedKVStart:kvScheme:)`. **That last
call is the site of the bug in §9.1.** Remember where it is.

### 4.5 Cancellation, and why the check is where it is

The generation loop is:

```swift illustrative
tokenLoop: while !Task.isCancelled {
    guard let token = iterator.next() else { break }
    …
}
```

The cancellation check is deliberately **before** `next()`, not after. The source explains:

> ✅ **VERIFIED** — `Evaluate.swift:1867-2001`, comment verbatim:
>
> > "next() calls asyncEval() to pipeline the next GPU evaluation, so checking after it (the
> > previous `while let token = iterator.next()` form) allowed one extra asyncEval to be submitted
> > post-cancellation, which faults if the app has backgrounded
> > (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`)."

The same hazard shows up in prefill, and the fix there is a cooperative check inside the chunk
loop:

```swift illustrative
public func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                    windowSize: Int?) throws -> PrepareResult {
    let prefillStepSize = windowSize ?? 512
    var y = input.text
    try withPreparedCache(cache, lengths: y.sequenceLengths) {
        var state: LMOutput.State? = state
        while y.tokens.size > prefillStepSize {
            try Task.checkCancellation()          // ← commit 2b03485
            autoreleasepool {
                let input = y[.newAxis, ..<prefillStepSize]
                let output = self(input, cache: cache.isEmpty ? nil : cache, state: state)
                state = output.state
                asyncEval(cache)
                y = y[prefillStepSize...]
            }
        }
        eval(cache)
    }
    return .tokens(y)
}
```

> ✅ **VERIFIED** — `Libraries/MLXLLM/LLMModel.swift`, the default chunked prefill, verbatim.
> The rationale comment (`LLMModel.swift:36-42`) is the clearest statement of why this matters on
> iOS:
>
> > "On iOS, GPU work submitted after the app moves to the background is rejected by the system
> > ('Insufficient Permission'), and the resulting command-buffer error is thrown from a Metal
> > completion handler where it cannot be caught, aborting the process."

**Read that twice.** The error is thrown from a Metal completion handler *where it cannot be
caught*, and it **aborts the process**. This is not "your generation fails"; it is "your app
crashes." Which is why the cancellation plumbing in this package is unusually thorough and why you
should not route around it.

Related landed work: `#382`/PR #389 ("Cancelling generation can still submit one more GPU
evaluation (iOS/iPadOS crash)"), PR #423 (cooperative cancellation in the prefill loop), PR #413
(cancel the generation task when the consumer goes away).

### 4.6 A complete streaming program with correct cancellation

Everything above, assembled as a complete SwiftPM executable target with the dependencies from
§1.2 (shown as a contextual excerpt — the external MLX modules keep it outside the compile-verified
set). It streams to stdout, times TTFT, handles a tool call if one appears, and cancels cleanly on
`SIGINT` — including waiting for the generation task to actually finish before exiting.

```swift prelude:external-module
// Sources/StreamDemo/main.swift
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// ---------------------------------------------------------------- configuration

private let modelConfiguration = LLMRegistry.qwen3_4b_4bit
private let parameters = GenerateParameters(maxTokens: 512, temperature: 0)
private let promptText = "Explain what a KV cache is, in three sentences."

// Bound the MLX buffer pool. Every Apple sample does this; 20 MB is their number.
// See §11.2 for why the "as big as fits" instinct is wrong here.
Memory.cacheLimit = 20 * 1024 * 1024

// ---------------------------------------------------------------- load

let container = try await #huggingFaceLoadModelContainer(
    configuration: modelConfiguration
) { progress in
    FileHandle.standardError.write(
        Data("\rdownload \(Int(progress.fractionCompleted * 100))%".utf8))
}

// ---------------------------------------------------------------- build the input

let chat: [Chat.Message] = [
    .system("You are terse and precise."),
    .user(promptText),
]

let userInput = UserInput(chat: chat)
let lmInput = try await container.prepare(input: userInput)
let promptTokenCount = lmInput.text.tokens.size

// ---------------------------------------------------------------- generate

// A holder so the signal handler can reach the task. `nonisolated(unsafe)` is the
// honest spelling: a signal handler is not an isolation domain.
nonisolated(unsafe) var generationTask: Task<Void, Never>?

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { generationTask?.cancel() }
sigintSource.resume()

let start = Date.timeIntervalSinceReferenceDate
var firstTokenAt: TimeInterval?
var completionInfo: GenerateCompletionInfo?

// Build the iterator (this is where prefill happens, and where it can throw),
// then hand it to generateTask so we get a handle we can await.
let (stream, task) = try await container.perform { context -> (AsyncStream<Generation>, Task<Void, Never>) in
    let iterator = try TokenIterator(
        input: lmInput,
        model: context.model,
        cache: nil,                  // let the model build its own; see §8.4
        parameters: parameters)

    return generateTask(
        promptTokenCount: promptTokenCount,
        modelConfiguration: context.configuration,
        tokenizer: context.tokenizer,
        iterator: iterator)
}

generationTask = task

for await item in stream {
    if firstTokenAt == nil { firstTokenAt = Date.timeIntervalSinceReferenceDate }

    switch item {
    case .chunk(let text):
        print(text, terminator: "")
        fflush(stdout)

    case .toolCall(let call):
        // A tool call can be the FIRST and ONLY event. See §2.5.
        FileHandle.standardError.write(
            Data("\n[tool call: \(call.function.name) \(call.function.arguments)]\n".utf8))

    case .info(let info):
        completionInfo = info
    }
}

// The critical two lines. Without them the GPU may still be working against the
// KV cache when the process exits or when the next turn starts. See §2.4.
task.cancel()
await task.value

// ---------------------------------------------------------------- report

print("")
if let firstTokenAt {
    let ttft = firstTokenAt - start
    FileHandle.standardError.write(Data(String(format: "TTFT %.3f s\n", ttft).utf8))
}
if let completionInfo {
    FileHandle.standardError.write(Data((completionInfo.summary() + "\n").utf8))
    FileHandle.standardError.write(Data("stop reason: \(completionInfo.stopReason)\n".utf8))
}
FileHandle.standardError.write(Data((Memory.snapshot().description + "\n").utf8))
```

**Six things this example is demonstrating, in order of how often they are gotten wrong:**

1. **`task.cancel()` then `await task.value`** after the loop. Not before, not instead of.
2. **TTFT is measured from before the `perform` block**, because prefill is inside
   `TokenIterator.init` (§4.2). Measuring from the first `for await` iteration measures nothing.
3. **The `.toolCall` case is handled explicitly** and can arrive first (§2.5).
4. **The stream is constructed inside `perform` and consumed outside it** (§2.3).
5. **`Memory.cacheLimit` is set once at startup.** `MLX.GPU.set(cacheLimit:)` — the idiom in every
   pre-2026 tutorial — **does not exist in this codebase any more**; it is `Memory.cacheLimit`,
   `Memory.memoryLimit`, `Memory.snapshot()`.
   > ✅ **VERIFIED** — `mlx-swift-examples` research notes §4: the old spelling appears **nowhere**
   > in that repo; the new `Memory` API is used in `LLMBasicApp.swift:12`, `MLXService.swift:56`,
   > `LLMEvaluator.swift:105`, `LoRATrainingExample/ContentView.swift:181`,
   > `StableDiffusionExample/ContentView.swift:146,149` and every CLI's `MemoryArguments`.
6. **`.info` is captured rather than assumed.** `llm-tool`'s equivalent loop ends with
   `fatalError("exited loop without seeing .info")` — the stream is *expected* always to terminate
   with `.info`, and Apple's CLI treats its absence as a programming error. In app code, don't
   `fatalError`; do notice.

**Observed `Memory.cacheLimit` values across Apple's own samples**, if you want a starting point:

| App | `cacheLimit` | `memoryLimit` |
|---|---|---|
| `LLMBasic` | 20 MB | — |
| `LLMEval` | 20 MB | — |
| `MLXChatExample` | 20 MB | — |
| `LoRATrainingExample` | 32 MB | — |
| `StableDiffusionExample` (low-memory device) | 1 MB | 3 GB |
| `StableDiffusionExample` (normal) | 256 MB | — |
| `llm-tool` / `embedder-tool` | `--cache-size` MB | `--memory-size` MB |

> ✅ **VERIFIED** — read from the named source files in `mlx-swift-examples` at HEAD `378f244`.
> These are configuration choices in Apple sample code, not benchmarks.

---

## 5. Input types

### 5.1 The pipeline, in one diagram

```
  Chat.Message[]  ─┐
  [String: any]   ─┼─▶  UserInput  ──▶  UserInputProcessor.prepare(input:)  ──▶  LMInput
  String          ─┘        │                       │                              │
                            │                       │                              ├─ text: LMInput.Text
                    images/videos/audios     LLMUserInputProcessor                  ├─ image: ProcessedImage?
                    tools / additionalContext  or a VLM processor                   ├─ video: ProcessedVideo?
                    processing (resize, px)    (Qwen2VLProcessor, Gemma4Processor…) └─ audio: ProcessedAudio?
```

`UserInputProcessor` is a one-method protocol and it is where all the model-specific work lives:

```swift prelude:guide-context
public protocol UserInputProcessor: Sendable {
    func prepare(input: UserInput) async throws -> LMInput
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/UserInput.swift:450-452`. The stand-in conformance
> `StandInUserInputProcessor` throws `UserInputError.notImplemented`, which is what you get if a
> model type is registered without a processor.

You reach the processor through the container:

```swift prelude:guide-context
let lmInput = try await container.prepare(input: userInput)          // convenience
// or, inside perform:
let lmInput = try await context.processor.prepare(input: userInput)  // explicit
```

### 5.2 `UserInput`

```swift prelude:guide-context
public typealias Message = [String: any Sendable]

public struct UserInput {
    public enum Prompt: CustomStringConvertible {
        case text(String)
        case messages([Message])       // model-specific dictionaries
        case chat([Chat.Message])      // model-agnostic
    }
    public var prompt: Prompt          // didSet re-derives images/videos/audios for .chat
    public var images  = [Image]()
    public var videos  = [Video]()
    public var audios  = [Audio]()
    public var tools: [ToolSpec]?
    public var additionalContext: [String: any Sendable]?
    public var processing: Processing = .init()
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/UserInput.swift`.

**Three prompt shapes, and which to use:**

| Case | When | Cost |
|---|---|---|
| `.text(String)` | never, in 2026 | no roles, no template structure |
| `.messages([[String: any Sendable]])` | you are hand-building the exact dicts a specific template wants | you own template compatibility |
| `.chat([Chat.Message])` | **default choice** | a `MessageGenerator` converts to dicts for you |

The initializers:

```swift illustrative
init(prompt: String, images:videos:audios:tools:additionalContext:)   // wraps into .chat([.user(...)])
init(messages: [Message], …)
init(chat: [Chat.Message], processing:tools:additionalContext:)
init(prompt: Prompt, images:videos:audios:processing:tools:additionalContext:)
```

⚠️ **A source comment worth quoting because it explains a whole class of confusion:**
`// note: prompt.didSet is not triggered in init`. Every initializer manually re-derives
`images` / `videos` / `audios` from the chat messages. If you construct a `UserInput` and *then*
mutate `.prompt`, the `didSet` fires and re-derives. If you mutate `.images` directly after
constructing from a chat, you now have media that the messages do not reference. **Put media on
the `Chat.Message`, not on the `UserInput`, whenever you use the `.chat` path.**

> ✅ **VERIFIED** — `UserInput.swift`, comment verbatim.

Media types:

```swift prelude:guide-context
public enum Image {
    #if canImport(CoreImage)
    case ciImage(CIImage)
    #endif
    case url(URL)
    case array(MLXArray)
    public func asCIImage() throws -> CIImage   // handles 0..1 scaling, planar→pixels, RGB→RGBA pad
}

public enum Video {
    #if canImport(AVFoundation)
    case avAsset(AVAsset)
    #endif
    case url(URL)
    case frames([VideoFrame])
}

public enum Audio { case url(URL); case array(MLXArray) }
public enum AudioFormat: Sendable { case linearPCM }
public struct VideoFrame { public let image: Image; public let timeStamp: CMTime }
```

> ✅ **VERIFIED** — `UserInput.swift:79-173`. The `#if canImport` guards are why this package
> compiles on Linux; `Libraries/MLXLMCommon/Linux/` contains `CoreGraphics.swift`,
> `CoreMedia.swift`, `Logger.swift`, `String+Linux.swift` shims (commit `65e28c2`).

Processing knobs:

```swift prelude:guide-context
public struct Processing: Sendable {
    public var resize: CGSize?
    public var audio = AudioProcessing()
    public var minPixels: Int?      // per-call override of the model's min_pixels
    public var maxPixels: Int?      // per-call override of the model's max_pixels
    public init(resize: CGSize? = nil, minPixels: Int? = nil, maxPixels: Int? = nil)
}

public struct AudioProcessing: Sendable {
    public var sampleRate = 48_000.0
    public var channels = 1
    public var audioFormat: AudioFormat = .linearPCM
}
```

> ✅ **VERIFIED** — `UserInput.swift:189-222`.

`minPixels` / `maxPixels` are the per-call escape hatch for Qwen-VL-family dynamic resolution. They
matter more than `resize` for those models, because the processor computes a token budget from the
pixel count. mlx-swift-lm PR #398 defaults Qwen3VL to a **1,280 vision-token budget per image**
after issue #396, where uncapped resolution let the ViT allocate tens of gigabytes.

### 5.3 `Chat.Message`

```swift illustrative
public enum Chat {
    public struct Message {
        public var role: Role                 // .user .assistant .system .tool
        public var content: String
        public var images: [UserInput.Image]
        public var videos: [UserInput.Video]
        public var audios: [UserInput.Audio]
        public var tool: Tool?                // .calls([ToolCall]) or .result(id: String)

        public static func system(_ content: String, images:…, videos:…) -> Self
        public static func assistant(_ content: String, images:…, videos:…,
                                     toolCalls: [ToolCall]? = nil) -> Self
        public static func user(_ content: String, images:…, videos:…, audios:…) -> Self
        public static func tool(_ content: String, id: String? = nil) -> Self
    }
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Chat.swift`.

`MessageGenerator` converts these to the raw `[String: any Sendable]` dicts a Jinja chat template
expects. The default emits `["role": …, "content": …]` plus tool metadata: `tool_calls` (an array
of `{type: "function", function: {name, arguments}, id?}`) on assistant messages, and
`tool_call_id` on tool results.

Two generators ship: `DefaultMessageGenerator` and `NoSystemMessageGenerator` (which filters
`.system` messages out entirely). **How the right one gets picked is a delightfully pragmatic piece
of code:**

> ✅ **VERIFIED** — `Libraries/MLXLLM/Models/Llama.swift:186-202`: `LlamaModel.messageGenerator(tokenizer:)`
> **probes the chat template with a system message and catches the throw.** If rendering a system
> message throws, it returns `NoSystemMessageGenerator`; otherwise `DefaultMessageGenerator`.

That is the library protecting you from a template that does not accept a system role. It is also a
hint about §6: **the template is the contract, and the library discovers the contract at runtime by
trying things.**

⚠️ **SILENT FAILURE #4 — a trailing empty assistant message closes the assistant turn.** If you
push a `.assistant("")` placeholder into the model input (a natural thing to do when your UI wants
a bubble to stream into), the chat template *closes* the assistant turn and generation misbehaves —
usually by producing a fresh user turn or an immediate EOS. `ChatSession` handles this internally.
**The raw `UserInput` path does not.** Apple's fix, added 2026-06-16:

```swift prelude:guide-context
// Exclude trailing empty assistant message so the chat template
// leaves the assistant turn open for generation (matching ChatSession behavior)
var inputMessages = messages
if let last = inputMessages.last, last.role == .assistant, last.content.isEmpty {
    inputMessages.removeLast()
}
```

> ✅ **VERIFIED** — `mlx-swift-examples/Applications/MLXChatExample/Services/MLXService.swift`,
> verbatim; commit `378f244` message: *"Exclude trailing empty assistant message from model
> input."*

### 5.4 `LMInput` and `LMOutput`

```swift illustrative
public struct LMInput {
    public let text: Text
    public let image: ProcessedImage?
    public let video: ProcessedVideo?
    public let audio: ProcessedAudio?

    public struct Text {
        public let tokens: MLXArray
        public let mask: MLXArray?
        public var sequenceLengths: [Int]?     // from mask, else uniform for 2-D tokens
        public subscript(indices: MLXArrayIndex..., stream:) -> Text        // slices tokens AND mask
        public subscript(text indices: MLXArrayIndex..., stream:) -> Text   // slices tokens only
    }
    public struct ProcessedImage {
        public let pixels: MLXArray
        public let positionIds: MLXArray?
        public let frames: [THW]?
    }
    public struct ProcessedVideo { /* identical shape */ }
    public struct ProcessedAudio { public let features: MLXArray; public let mask: MLXArray? }
}

public struct THW: Sendable {
    public let t, h, w: Int
    public var values: (Int, Int, Int)
    public var product: Int
}

public enum PrepareResult { case tokens(LMInput.Text); case logits(LMOutput) }
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/LanguageModel.swift`.

**`lmInput.text.tokens.size` is your prompt token count.** That is how Apple's `LLMEval` computes
it, and it is the number you want for TTFT-per-token and for sizing a KV budget (§8.8).

The two subscripts are subtle and worth calling out: the default one **slices tokens and mask
together**; the `[text: …]` one slices tokens only. Chunked prefill uses the first. If you write a
custom prefill and use the wrong one, your attention mask desynchronises from your tokens — and
because a mask mismatch usually produces *plausible* attention rather than a crash, you get
degraded output with no error.

### 5.5 The `LanguageModel` protocol, and where `PrepareResult` splits

```swift prelude:guide-context
public protocol LanguageModel: BaseLanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, windowSize: Int?)
        throws -> PrepareResult

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput
    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray
    func newCache(parameters: GenerateParameters?) -> [KVCache]
}
```

> ✅ **VERIFIED** — `LanguageModel.swift:238-266`.

`PrepareResult` has two cases and **the difference is the whole LLM/VLM split**:

- **`.tokens(LMInput.Text)`** — "I prefilled everything except this tail; now iterate normally."
  That is the LLM path (§4.5's chunked prefill returns `.tokens(y)`).
- **`.logits(LMOutput)`** — "I ran the whole thing including the last position; here are the
  logits and the state." That is the VLM path, because a VLM must merge image embeddings with text
  embeddings before it can run a forward at all.

`TokenIterator.prepare(input:windowSize:)` handles both, and the `.logits` branch does
`self.state = result.state` — **which is exactly the line that was missing in `#419`** (fixed in
commit `42f08a8`). One missing assignment on one branch, and every VLM lost its M-RoPE deltas.

### 5.6 The VLM path in practice

`UserInputProcessor.prepare(input:)` for a vision model has to do a specific sequence, and
`MediaProcessing` (`Libraries/MLXVLM/MediaProcessing.swift`, 571 lines) supplies each step:

1. **sRGB tone-curve conversion** — `MediaProcessing.inSRGBToneCurveSpace(_:)`.
2. **Apply the user's `Processing`** — `MediaProcessing.apply(_:processing:)`.
3. **Resample** — `resampleLanczos(_:to:)` or `resampleBicubic(_:to:)`.
4. **Normalize** — `normalize(_:mean:std:)` with the model's per-channel constants.
5. **`asMLXArray(_:colorSpace:)`**.
6. **Inject the model's image placeholder tokens into the text stream.**

> ✅ **VERIFIED** — `Libraries/MLXVLM/MediaProcessing.swift` public surface; step list from
> `Documentation.docc/porting.md`'s VLM processor section.

Step 1 is not cosmetic. mlx-swift-lm PR #411 fixed Qwen3VL specifically because the tone curve was
not being applied: *"linear-light values made dark content unreadable"* (issue #410). A VLM fed
linear-light pixels does not error; it just fails to see things in shadow.

Step 6 is where most porting bugs live. The processor must place exactly as many placeholder tokens
as the vision tower will produce embeddings for. Get it wrong and shapes mismatch — which, on this
stack, sometimes means a broadcast crash and sometimes means silently misaligned attention.

**Chunked prefill matters more for VLMs than for LLMs.** The VLM `prepare` should merge
image+text embeddings and then loop in `windowSize ?? 512` chunks with `asyncEval(cache)`, ending
with one `.logits(result)`. The source comment states the failure mode plainly: *"Single-pass
prefill allocates transient buffers proportional to prompt length and causes OOM on long prompts."*

> ✅ **VERIFIED** — pattern and comment from `Libraries/MLXVLM/README.md:273-305`.

**How processors get selected**, because this trips people:

- The VLM factory reads `preprocessor_config.json` **in preference to** `processor_config.json`.
- The declared `processor_class` is then **overridden** for two model types:

```swift compile:27
let processorTypeOverrides: [String: String] = [
    "mistral3": "Mistral3Processor",
    "gemma4_unified": "Gemma4UnifiedProcessor",
]
```

with the source comment: *"Mistral3 models ship with 'PixtralProcessor' in their config but need
Mistral3Processor to handle spatial merging correctly."*

> ✅ **VERIFIED** — `Libraries/MLXVLM/VLMModelFactory.swift:419-476`.

⚠️ **The VLM factory is tried *before* the LLM factory** by the free-function loading path, and
failures are swallowed — only the **last** error propagates. If a load fails with a confusing
message, that message may be from the wrong factory.

> ✅ **VERIFIED** — `ModelFactory.swift:413-497`; the registry uses `NSClassFromString` dynamic
> discovery with VLM first, LLM second. Corollary: **if neither `MLXLLM` nor `MLXVLM` is linked
> into your binary you get `ModelFactoryError.noModelFactoryAvailable`** before the downloader is
> ever reached, because module-init is what registers the factories.

Finally, two device-side realities from Apple's samples that no amount of library correctness will
fix for you:

- **`CIImage(contentsOf:)` ignores EXIF orientation.** A photo from the camera roll arrives
  rotated. Apple's fix re-renders pixels through `UIGraphicsImageRenderer` before writing the JPEG.
- **`PhotosPicker`'s `loadTransferable(type: Data.self)` is unreliable.** Declare explicit
  `Transferable` wrappers with `DataRepresentation(importedContentType: .image)` /
  `FileRepresentation(importedContentType: .movie)` and **copy** the file out of
  `receivedFile.file` before the picker's temporary URL goes away.
- **`fileImporter` URLs need `startAccessingSecurityScopedResource()` / `stop…`.**

> ✅ **VERIFIED** — all three from `mlx-swift-examples` commit `378f244`
> ("fix VLM image handling on iOS (PhotosPicker, EXIF, empty assistant trim) (#472)") and
> `ChatViewModel.swift:158-188`.

---

## 6. Tokenizers and chat templates

### 6.1 The protocol is nine methods, and it returns token IDs

In 3.x the tokenizer is **yours**. The package declares what it needs and nothing more:

```swift illustrative
public protocol Tokenizer: Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?

    var bosToken: String? { get }
    var eosToken: String? { get }
    var unknownToken: String? { get }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Tokenizer.swift:6-21`.

**Read the return type of `applyChatTemplate`: `[Int]`, not `String`.** Unlike Python's
`tokenizer.apply_chat_template(..., tokenize=False)`, the Swift protocol has **no un-tokenized
rendering mode**. You cannot ask for the rendered prompt text. That is the single most important
fact in this section, because it means the obvious way to inspect a template does not exist and you
have to go around (§6.4).

Extension defaults:

```swift prelude:guide-context
encode(text:)      // ⇒ addSpecialTokens: true
decode(tokenIds:)  // ⇒ skipSpecialTokens: FALSE
```

> ✅ **VERIFIED** — `Tokenizer.swift:23-54`. The `skipSpecialTokens: false` default is deliberate
> and documented against `ReasoningConfig.isSpecialToken`: it is **why reasoning delimiters render
> as literal `<think>` / `</think>` text** in your output rather than vanishing.

One typed error exists: `TokenizerError.missingChatTemplate` (`Tokenizer.swift:56-65`). The
`MLXHuggingFace` bridge translates `Tokenizers.TokenizerError.missingChatTemplate` into it.

### 6.2 How templates get resolved

There is no template *resolution* logic in `MLXLMCommon` at all. The chain is:

```
ModelConfiguration.tokenizerSource  ──▶ a directory on disk
                                          │
                       downloaded with:   │  ["*.json", "*.jinja"]
                                          ▼
                 TokenizerLoader.load(from: directory) ──▶ any Tokenizer
                                          │
                     (#huggingFaceTokenizerLoader() ⇒ Tokenizers.AutoTokenizer.from(modelFolder:))
                                          ▼
                     tokenizer.applyChatTemplate(messages:tools:additionalContext:)
```

> ✅ **VERIFIED** — download patterns from `Libraries/MLXLMCommon/ModelFactory.swift:5-7`:
> ```swift
> package let tokenizerDownloadPatterns = ["*.json", "*.jinja"]
> package let modelDownloadPatterns = ["*.safetensors"] + tokenizerDownloadPatterns
> ```
> Loader macro expansion from `MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`.

Note `*.jinja` in the patterns: a repo may ship `chat_template.jinja` separately from
`tokenizer_config.json`, and the downloader fetches both.

**The tokenizer can come from a different repo than the weights.** `TokenizerSource` is:

```swift compile:27 imports:Foundation
public enum TokenizerSource: Sendable, Equatable {
    case id(String, revision: String? = nil)
    case directory(URL)
}
```

with `nil` meaning "same directory as the model." When `.id` is used, the tokenizer download runs
with `tokenizerDownloadPatterns` **and a no-op progress handler** — so a slow tokenizer fetch looks
like a hang in your progress UI.

> ✅ **VERIFIED** — `Downloader.swift:48-57`, `ModelFactory.swift:228-263`.

### 6.3 Stop tokens: four sources, one of which overwrites the others

Where generation decides to stop is assembled from four places, and the assembly rules are not
symmetric.

**At load time** (`LLMModelFactory._load`, `Libraries/MLXLLM/LLMModelFactory.swift:569-669`):

1. Start with `baseConfig.effectiveEOSTokenIds` — the root `eos_token_id` from `config.json`, **or**
   `text_config.eos_token_id` if the root has none.
2. If `generation_config.json` has an `eos_token_id`, **replace** the set entirely:
   ```swift prelude:guide-context
   eosTokenIds = Set(genEosIds)  // Override per Python mlx-lm behavior
   ```
3. `stopStrings.formUnion(generationConfig?.stopStrings ?? [])`.

**At generation time** (`buildStopTokenIds`, `Evaluate.swift:1170-1185`), the loop builds
`stopTokenIds` as the union of:
`modelConfiguration.eosTokenIds` ∪ `tokenizer.eosTokenId` ∪ `extraEOSTokens` mapped through
`convertTokenToId`.

> ✅ **VERIFIED** — both, from the cited files.

⚠️ **Step 2 is a replace, not a union, and it is deliberate** — it matches Python mlx-lm. So a
model whose `config.json` lists three EOS ids and whose `generation_config.json` lists one ends up
with **one**. If a model stops too late (rambling past its turn) or too early, this is the first
thing to check.

⚠️ **`stopStrings == nil` falls back to `extraEOSTokens`.** `ModelConfiguration` has:

```swift prelude:guide-context
public var stopStrings: Set<String>?
public var effectiveStopStrings: Set<String> { stopStrings ?? extraEOSTokens }
```

so **to disable stop strings you must set `stopStrings: []` explicitly** — `nil` does not mean
"none," it means "use the EOS token strings." This is a genuinely surprising default and it is the
kind of thing that makes a model appear to truncate mid-sentence when its EOS string happens to
occur in normal prose.

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/ModelConfiguration.swift:16-184`.

Stop-string handling itself is careful: `StopStringFilter` buffers text, **sorts stop strings
longest-first**, emits text up to the earliest match, and holds back the longest partial suffix
that could still complete a stop string. That last clause is why you never see half a stop string
leak into your UI — and also why a very long stop string introduces latency at the tail of every
generation.

> ✅ **VERIFIED** — `Evaluate.swift:2219-2303`.

The `LLMRegistry` presets encode per-family knowledge you would otherwise have to discover:

```swift illustrative
static public let gemma3_1B_qat_4bit = ModelConfiguration(
    id: "mlx-community/gemma-3-1b-it-qat-4bit", …, extraEOSTokens: ["<end_of_turn>"])

static public let gemma4_e4b_it_4bit = ModelConfiguration(
    id: "mlx-community/gemma-4-e4b-it-4bit", …, extraEOSTokens: ["<turn|>"])

static public let qwen3_4b_4bit = ModelConfiguration(
    id: "mlx-community/Qwen3-4B-4bit", …, extraEOSTokens: ["<|im_end|>"])

static public let llama3_2_3B_4bit = ModelConfiguration(
    id: "mlx-community/Llama-3.2-3B-Instruct-4bit", …, extraEOSTokens: ["<|eot_id|>"])
```

> ✅ **VERIFIED** — `Libraries/MLXLLM/LLMModelFactory.swift`, `LLMRegistry` statics.

⚠️ **A model you load by bare id gets none of that.** `AbstractModelRegistry.configuration(id:)`
**returns a fresh `ModelConfiguration(id:)` for unknown ids** — so unknown models "just work,"
with empty `extraEOSTokens`, no `toolCallFormat`, and no `reasoningConfig`. Use
`contains(id:)` to find out whether you got a curated preset or a blank one.

### 6.4 ⚠️ SILENT FAILURE #5 — the chat template is the contract, and nothing checks it

**This is the one to internalise.** A mismatched, missing, or partially-honoured chat template
produces **fluent, plausible, degraded output**. Not gibberish. Not an error. Slightly worse
instruction-following, slightly worse tool use, slightly more rambling — the kind of quality loss
that gets attributed to "the model just isn't very good" and never gets debugged.

Four distinct ways it happens on the Swift side:

**(A) No template at all.** If the tokenizer has no chat template, `applyChatTemplate` throws
`TokenizerError.missingChatTemplate` — this one is *loud*, and it is the good case. But if you have
built a `UserInput` with `.text(String)` instead of `.chat([...])`, or if you are calling
`tokenizer.encode(text:)` yourself, **no template is applied and nothing throws**. You are sending
raw text to an instruct-tuned model. It answers. It answers worse.

**(B) The system message is silently dropped.** `NoSystemMessageGenerator` exists precisely because
some templates reject a system role — and the library selects it by *probing and catching the
throw* (§5.3). That is the right behaviour, but the consequence is that **your carefully written
system prompt can be discarded with no diagnostic.** The model still responds; it just was never
told who it is.

> ✅ **VERIFIED** — `Libraries/MLXLLM/Models/Llama.swift:186-202`.

**(C) `additionalContext` keys the template does not read.** `additionalContext` is
`[String: any Sendable]` and is passed straight through to the template renderer. Jinja **ignores
unknown variables**. So `additionalContext: ["enable_thinking": false]` on a model whose template
never references `enable_thinking` does exactly nothing — no error, no warning, and reasoning stays
on. `ReasoningPromptStrategy` encodes which models actually honour it:

```swift illustrative
public enum ReasoningPromptStrategy: Sendable, Equatable {
    case templateFlag(key: String, defaultOn: Bool)     // e.g. Qwen3 "enable_thinking"
    case alwaysOn                                       // DeepSeek-R1
    case none
    public func additionalContext(forThinkingEnabled thinkingEnabled: Bool?) throws
        -> [String: any Sendable]?
}
```

and inference is by `model_type` prefix — `qwen3*` ⇒ `.templateFlag(key: "enable_thinking",
defaultOn: true)`; `deepseek_v3` / `deepseek_r1`, **or a repo id containing `deepseek-r1` or
`r1-distill`**, ⇒ `.alwaysOn`; everything else ⇒ `nil`. Note the `ReasoningError`:
`.cannotDisableReasoning` — for `.alwaysOn` models, asking to turn thinking off is a typed error
rather than a silent no-op. That is the right design, and it exists for exactly two families.

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/ReasoningConfig.swift`, inference rules at lines 130-164.
> The doc explains why `modelId` is load-bearing in the DeepSeek rule: **R1-Distill checkpoints
> report `model_type` as `qwen2` or `llama`**, so type alone cannot identify them.

**(D) The tool-call format is inferred from `model_type`, and can be wrong or absent.** Covered in
full in §7.5. The short version: `ToolCallFormat.infer` returns `nil` for most model types, the
generation loop then uses `configuration.toolCallFormat ?? .json`, and a model that emits a
non-JSON format gets its tool calls **left in the prose as text** with `stopReason == .stop` and
`toolCalls == []`.

### 6.5 The render-and-eyeball recipe

Because `applyChatTemplate` returns `[Int]`, you cannot print the rendered prompt directly. You
**decode it back** — and crucially you decode with `skipSpecialTokens: false`, which is the default,
so the special tokens are visible. That round trip is the verification.

```swift prelude:external-module
// Sources/TemplateCheck/main.swift
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

let container = try await #huggingFaceLoadModelContainer(
    configuration: LLMRegistry.qwen3_4b_4bit)

// A probe conversation containing every element whose survival you care about.
let probe: [Chat.Message] = [
    .system("SYSTEM_SENTINEL"),
    .user("USER_SENTINEL"),
    .assistant("ASSISTANT_SENTINEL"),
    .user("SECOND_USER_SENTINEL"),
]

let probeTool: ToolSpec = [
    "type": "function",
    "function": [
        "name": "TOOL_SENTINEL",
        "description": "a probe tool",
        "parameters": [
            "type": "object",
            "properties": ["x": ["type": "string", "description": "probe"]],
            "required": ["x"],
        ] as [String: any Sendable],
    ] as [String: any Sendable],
]

await container.perform { context in
    let generator = DefaultMessageGenerator()
    let messages = generator.generate(messages: probe)

    do {
        let ids = try context.tokenizer.applyChatTemplate(
            messages: messages,
            tools: [probeTool],
            additionalContext: ["enable_thinking": false])

        // skipSpecialTokens defaults to FALSE — that is what makes this useful.
        let rendered = context.tokenizer.decode(tokenIds: ids)

        print("──── rendered prompt (\(ids.count) tokens) ────")
        print(rendered)
        print("──── checks ────")
        for sentinel in ["SYSTEM_SENTINEL", "USER_SENTINEL", "ASSISTANT_SENTINEL",
                         "SECOND_USER_SENTINEL", "TOOL_SENTINEL"] {
            print(rendered.contains(sentinel) ? "  ✓ \(sentinel)" : "  ✗ \(sentinel)  ← DROPPED")
        }
        print("  thinking markers present: \(rendered.contains("<think>"))")

    } catch let error as TokenizerError {
        print("template error: \(error)")     // .missingChatTemplate is the loud, good case
    } catch {
        print("unexpected: \(error)")
    }

    print("──── configuration ────")
    print("  eosTokenIds        : \(context.configuration.eosTokenIds)")
    print("  extraEOSTokens     : \(context.configuration.extraEOSTokens)")
    print("  effectiveStopStrings: \(context.configuration.effectiveStopStrings)")
    print("  toolCallFormat     : \(String(describing: context.configuration.toolCallFormat))")
    print("  reasoningConfig    : \(String(describing: context.configuration.reasoningConfig))")
}
```

**How to read the output:**

| Symptom | Meaning | Fix |
|---|---|---|
| `✗ SYSTEM_SENTINEL` | template rejects or ignores a system role | fold your instructions into the first user message |
| `✗ TOOL_SENTINEL` | the template does not render tools | tool calling will not work; §7.8 |
| `<think>` present when you asked for `enable_thinking: false` | the template ignores that key | check `reasoningConfig`; the key may be named differently or the model may be `.alwaysOn` |
| `toolCallFormat: nil` | inference found nothing; the loop will assume `.json` | set `toolCallFormat:` explicitly; §7.5 |
| `effectiveStopStrings` unexpectedly non-empty | `stopStrings` is `nil`, so it fell back to `extraEOSTokens` | set `stopStrings: []` to disable |
| The whole thing throws `.missingChatTemplate` | the tokenizer directory has no template | this is the good failure; supply one |

**Run this once per model you ship.** It costs one launch and it catches every variant of §6.4.

> This recipe is composed from verified APIs (`applyChatTemplate`, `decode(tokenIds:)`,
> `DefaultMessageGenerator`, `ModelConfiguration` fields) rather than copied from a shipping
> source file. The **APIs** are ✅ VERIFIED as cited above; the **assembly** is this guide's.

### 6.6 Streaming detokenization

The last piece: turning token IDs back into text you can append to a label, incrementally.

```swift compile:27
public protocol StreamingDetokenizer: IteratorProtocol<String> {
    mutating func append(token: Int)
}
```

The shipped `NaiveStreamingDetokenizer`:

- **re-decodes the whole current segment each step** (so it is O(T²) within a segment),
- returns `nil` while a partial UTF-8 sequence is pending — detected by `new.last == "\u{fffd}"`,
- **restarts the segment on `"\n"`**, which is what bounds the quadratic cost in practice.

> ✅ **VERIFIED** — `Tokenizer.swift:67-114`.

The `nil`-while-pending behaviour is why you must never assume one token yields one chunk. A CJK
character, an emoji, or any multi-byte grapheme spans several tokens and the detokenizer correctly
emits nothing until it is complete. **A UI that counts `.chunk` events as a progress signal will
appear to stall on non-Latin text.** Count tokens (via `generateTokens`) if you need a progress
signal; count chunks only for display.

Python's equivalent has three implementations — `NaiveStreamingDetokenizer`,
`SPMStreamingDetokenizer`, `BPEStreamingDetokenizer` — selected by inspecting `tokenizer.json`'s
`decoder` field. **Swift ships only the naive one.** For very long single-line outputs (a
minified JSON blob, say) the Swift path does measurably more work per token than Python's. No
number is published for the gap; if it matters to you, measure it.

> 🔴 **GAP — the cost of Swift's naive-only detokenization is unquantified.** *What is unknown:*
> how much decode throughput `NaiveStreamingDetokenizer` costs versus a linear SPM/BPE
> detokenizer, on a long newline-free generation. *What would resolve it:* a benchmark generating
> ~4k tokens of newline-free output with `generateTokens` (raw ids, no detokenizer) versus
> `generate` (detokenized), same seed, same machine. *Safe default:* if you are generating long
> structured output with no newlines and decode looks slower than it should, use `generateTokens`
> and detokenize in batches yourself.

---

## 7. Tool calling: ten formats and why

### 7.1 Declaring a tool

```swift illustrative
public typealias ToolSpec = [String: any Sendable]

public protocol ToolProtocol: Sendable {
    var schema: ToolSpec { get }
}

public struct Tool<Input: Codable, Output: Codable>: ToolProtocol {
    public let schema: ToolSpec
    public let handler: @Sendable (Input) async throws -> Output
    public var name: String        // reads schema["function"]["name"]

    public init(name: String, description: String, parameters: [ToolParameter],
                handler: @Sendable @escaping (Input) async throws -> Output)
    public init(schema: ToolSpec, handler: @Sendable @escaping (Input) async throws -> Output)
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Tool/Tool.swift`.

The synthesized schema is **OpenAI-shaped**, regardless of which of the ten wire formats the model
will use to *call* it:

```json
{"type":"function",
 "function":{"name":"…","description":"…",
   "parameters":{"type":"object","properties":{…},"required":[…]}}}
```

That separation is the design: **one schema language in, ten serialisations out.** You describe the
tool once; the format machinery deals with how a given family spells the invocation.

Parameters:

```swift illustrative
public indirect enum ToolParameterType {
    case string, bool, int, double
    case array(elementType: ToolParameterType)
    case object(properties: [ToolParameter])
    case data                                   // {"type":"string","contentEncoding":"base64"}
}

public static func required(_ name: String, type: ToolParameterType, description: String,
                            extraProperties: [String: any Sendable] = [:]) -> ToolParameter
public static func optional(_ name: String, type: ToolParameterType, description: String,
                            extraProperties: [String: any Sendable] = [:]) -> ToolParameter
```

> ✅ **VERIFIED** — `Tool/ToolParameter.swift`; schema output verified against
> `Tests/MLXLMTests/ToolTests.swift:41-90`, which confirms that
> `.optional("unit", …, extraProperties: ["enum": ["celsius","fahrenheit"]])` **merges `enum` into
> that property's schema**.

`extraProperties` is the escape hatch for everything JSON Schema supports that the enum does not —
`enum`, `default`, `minimum`, `pattern`. Apple's `LLMEval` sample uses it exactly that way:

```swift prelude:guide-context
let currentWeatherTool = Tool<WeatherInput, WeatherOutput>(
    name: "get_current_weather",
    description: "Get the current weather in a given location",
    parameters: [
        .required("location", type: .string,
                  description: "The city and state, e.g. San Francisco, CA"),
        .optional("unit", type: .string, description: "The unit of temperature",
                  extraProperties: ["enum": ["celsius", "fahrenheit"], "default": "celsius"]),
    ]
) { input in
    let range = input.unit == "celsius" ? (min: -20.0, max: 40.0) : (min: 0, max: 100)
    let temperature = Double.random(in: range.min ... range.max)
    let conditions = ["Sunny", "Cloudy", "Rainy", "Snowy", "Windy", "Stormy"].randomElement()!
    return WeatherOutput(temperature: temperature, conditions: conditions)
}
```

> ✅ **VERIFIED** — `mlx-swift-examples/Applications/LLMEval/Services/ToolExecutor.swift`,
> verbatim. Input/output types are plain `Codable` structs:
> `struct WeatherInput: Codable { let location: String; let unit: String? }`,
> `struct EmptyInput: Codable {}`.

### 7.2 `ToolCall`, and executing one

```swift prelude:guide-context
public struct ToolCall: Hashable, Codable, Sendable {
    public struct Function: Hashable, Codable, Sendable {
        public let name: String
        public let arguments: [String: JSONValue]
        public init(name: String, arguments: [String: JSONValue])
        public init(name: String, arguments: [String: any Sendable])
    }
    public let function: Function
    public let id: String?
    public init(function: Function, id: String? = nil)

    public func execute<Input, Output>(with tool: Tool<Input, Output>) async throws -> Output
}

public enum ToolError: Error, LocalizedError {
    case nameMismatch(toolName: String, functionName: String)
}
```

> ✅ **VERIFIED** — `Tool/ToolCall.swift`.

`execute(with:)` JSON-encodes the arguments and does `JSONDecoder().decode(Input.self, …)`, so
**your `Input` type is the schema validator**. A model that hallucinates an argument name gets a
`DecodingError`, which is exactly where you want that failure. It throws
`ToolError.nameMismatch` if you hand a call to the wrong tool.

Feeding results back: `Encodable.toolResult` (in `Extensions/Encodable+toolResult.swift`) encodes
any `Encodable` to a **snake_case JSON string**, returning `"{}"` on failure.

⚠️ **`"{}"` on failure is a silent degradation.** If your `Output` type fails to encode, the model
receives an empty object and cheerfully invents an answer. It is a small surface — plain `Codable`
structs rarely fail to encode — but if you put a non-encodable type in an `Output`, this is where
it goes quiet.

**Tool-call IDs** are generated by the format:
`.mistral` ⇒ the first 9 characters of a UUID with dashes stripped; **everything else** ⇒
`"call_" + lowercased uuid`. Mistral's template requires exactly-9-character alphanumeric ids, so
this is not arbitrary.

> ✅ **VERIFIED** — `ToolCallFormat.generateToolCallID()`.

### 7.3 The ten formats

Here is the complete enumeration. `ToolCallFormat` is
`public enum ToolCallFormat: String, Sendable, Codable, CaseIterable` — so you can iterate
`ToolCallFormat.allCases` and you can serialise it into a config file by its raw value.

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Tool/ToolCallFormat.swift:64-103`. Wire examples are
> quoted from the doc comments on each case.

| # | Case | Raw value | Wire format | Parser |
|---|---|---|---|---|
| 1 | `.json` | `json` | `<tool_call>{"name":…,"arguments":{…}}</tool_call>` | `JSONToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>")` |
| 2 | `.lfm2` | `lfm2` | `<\|tool_call_start\|>[func(arg='value')]<\|tool_call_end\|>` | `PythonicToolCallParser` |
| 3 | `.xmlFunction` | `xml_function` | `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>` | `XMLFunctionParser` |
| 4 | `.glm4` | `glm4` | `func<arg_key>k</arg_key><arg_value>v</arg_value>` | `GLM4ToolCallParser` |
| 5 | `.gemma` | `gemma` | `<start_function_call>call:name{key:value,k:<escape>str<escape>}<end_function_call>` | `GemmaFunctionParser(escapeMarker: "<escape>")` |
| 6 | `.gemma4` | `gemma4` | `<\|tool_call>call:name{key:<\|"\|>value<\|"\|>}<tool_call\|>` | `GemmaFunctionParser(escapeMarker: "<\|\"\|>")` |
| 7 | `.kimiK2` | `kimi_k2` | `functions.name:0<\|tool_call_argument_begin\|>{"key":"value"}` | `KimiK2ToolCallParser` |
| 8 | `.minimaxM2` | `minimax_m2` | `<invoke name="f"><parameter name="k">v</parameter></invoke>` | `MiniMaxM2ToolCallParser` |
| 9 | `.mistral` | `mistral` | `[TOOL_CALLS]get_weather [ARGS]{"location": "Tokyo"}` | `MistralToolCallParser` |
| 10 | `.llama3` | `llama3` | `<\|python_tag\|>{ "name": …, "parameters": {…} }` | `Llama3ToolCallParser` |

Ten cases, eight distinct parser classes (`GemmaFunctionParser` serves cases 5 and 6 with different
escape markers).

The parser protocol:

```swift illustrative
public protocol ToolCallParser: Sendable {
    var startTag: String? { get }        // nil for inline formats
    var endTag: String? { get }
    func parse(content: String, tools: [[String: any Sendable]]?) -> ToolCall?
    func parseEOS(_ toolCallBuffer: String, tools: [[String: any Sendable]]?) -> [ToolCall]
}
```

> ✅ **VERIFIED** — `Tool/ToolCallFormat.swift`.

`parseEOS` exists because **not every format has an end tag that arrives as text**. Mistral's
`[TOOL_CALLS]` block is terminated by `</s>`, which is intercepted at the *token-ID* level and
never reaches the text stream. So the processor holds a buffer and, at end-of-stream, hands it to
`parseEOS`. Same for LFM2's pythonic form, which is closed by bracket balance rather than a tag.

### 7.4 Why there are ten, and why there will be more

It is tempting to read that table as chaos. It is not; it is a faithful record of an ecosystem
fact, and the fact is worth stating explicitly because it drives every design decision downstream:

**Every model family invented its own tool-call serialisation, independently, at roughly the same
time, and none of them is going away.**

The reasons are structural, not accidental:

1. **Tool calls are emitted by the *decoder*, so they must be tokenizer-friendly.** A format built
   from tokens the model already has (`<|python_tag|>`, `[TOOL_CALLS]`) trains better than one that
   fragments into a dozen subword pieces. Every family's vocabulary is different, so every family's
   cheapest delimiter is different.
2. **The format is baked into the fine-tune.** By the time a checkpoint is published, the format is
   a property of the weights. You cannot ask Mistral to emit Qwen's format any more than you can
   ask it to speak a different language; it would be out of distribution.
3. **Some formats are not JSON on purpose.** LFM2's pythonic `[func(arg='value')]` and Gemma's
   `call:name{key:value}` are shorter in tokens than the equivalent JSON, which matters when your
   tool-calling budget is competing with your answer budget in a 4k context. GLM4's
   `<arg_key>`/`<arg_value>` pairs avoid JSON escaping entirely.
4. **Nested structure is hard.** `xmlFunction` and `minimaxM2` use XML-ish nesting because a model
   emitting a deeply nested JSON object token-by-token has many more ways to produce something
   unparseable. Tag-delimited formats fail more gracefully.

**The consequence for your code is the good news:** you write `Tool<Input, Output>` once, and the
library's job is to know which of ten dialects the loaded model speaks. **The consequence for your
testing is the bad news:** a tool-calling app that works perfectly on Qwen3 can fail completely on
Gemma 4 with no error, because the format machinery silently guessed wrong (§7.5).

The Python side has the same problem and solves it differently, which is worth knowing if you work
in both:

| | MLX Swift | mlx-lm (Python) |
|---|---|---|
| Format identity | a `ToolCallFormat` enum case | a module in `mlx_lm/tool_parsers/` |
| Count | **10 enum cases**, 8 parser types | **10 parser modules** |
| Detection input | `model_type` from `config.json` (+ `vocab_size`, `rope_scaling` for llama) | **substring matching on the chat-template text** |
| Explicit override | `ModelConfiguration.toolCallFormat` | `tool_parser_type` key in `tokenizer_config.json` |
| Streaming | `ToolCallProcessor`, a 4-state machine | `TextStateMachine` + Aho–Corasick trie |

> ✅ **VERIFIED** — Swift from `Tool/ToolCallFormat.swift`; Python from `mlx_lm/tool_parsers/` and
> `mlx_lm/tokenizer_utils.py`'s `_infer_tool_parser(chat_template)`.

**The two detection strategies fail differently, and that difference is instructive.** Python reads
the template — the thing that actually determines what the model will emit — so it is right more
often, but it is order-sensitive: `_infer_tool_parser` tests literal substrings in a fixed order,
and a template containing both `<tool_call>` and `<function=` gets `qwen3_coder`, not `json_tools`.
Swift reads `model_type` — a coarser signal, but a stable one that does not change when someone
edits a template. Neither is obviously better. Both can be overridden, and **on both sides you
should override explicitly for anything you ship.**

The two parser sets are close but not identical. Swift has `.llama3` (the `<|python_tag|>` form);
Python's list as read does not name a llama3 module. Python has `function_gemma`, `longcat`,
`qwen3_coder` and `glm47` as separate modules where Swift folds the corresponding shapes into
`.gemma`, `.xmlFunction` and `.glm4`. **Do not assume a model that parses in one language parses in
the other.**

### 7.5 Detection: `ToolCallFormat.infer`, rule by rule

```swift illustrative
public static func infer(from modelType: String, configData: Data? = nil) -> ToolCallFormat?
```

The rules, in evaluation order:

| Test on `model_type` | Result | Note |
|---|---|---|
| `"llama"` **and** (`vocab_size >= 128000` **or** `rope_scaling.rope_type == "llama3"`) | `.llama3` | needs a **secondary signal** from `configData` |
| `"llama"` without that signal | `nil` | Llama 2-era checkpoints have no tool format |
| prefix `lfm2` | `.lfm2` | |
| prefix `glm4` | `.glm4` | |
| prefix `gemma4` | `.gemma4` | |
| **exactly** `gemma` | `.gemma` | ⚠️ exact equality, not prefix — see below |
| prefix `nemotron` | `.xmlFunction` | |
| prefix `qwen3_5` | `.xmlFunction` | |
| prefix `qwen3_next` | `.xmlFunction` | |
| prefix `mistral3` | `.mistral` | |
| anything else | `nil` | |

> ✅ **VERIFIED** — `Tool/ToolCallFormat.swift`, `infer(from:configData:)`.

**And then the load path does this:**

```swift prelude:guide-context
toolCallFormat ← ToolCallFormat.infer(from: baseConfig.modelType, configData: configData)
                 // …only if configuration.toolCallFormat was not preset
```

**and the generation loop does this:**

```swift prelude:guide-context
configuration.toolCallFormat ?? .json
```

> ✅ **VERIFIED** — `Libraries/MLXLLM/LLMModelFactory.swift:569-669` (step 6) and the
> `TextToolTokenLoopHandler` construction in `Evaluate.swift`.

⚠️ **SILENT FAILURE #6 — `nil` becomes `.json`, and a non-JSON model's tool calls end up in your
prose.** Read the two lines above together. Inference returns `nil` for **most** model types —
plain `qwen2`, `qwen3`, `phi3`, `granite`, `olmo3`, `smollm3`, everything not in the table. The
loop then parses with `.json`, looking for `<tool_call>…</tool_call>`. A model that emits some
other shape produces:

- `stopReason == .stop` (normal termination),
- `toolCalls == []`,
- and **the tool-call text intact, inline, in the `.chunk` stream** — so it appears in your UI as
  the assistant reciting a function call at the user.

On affected releases there is no error or warning; the tool loop simply never fires.

> ✅ **VERIFIED** — this exact failure is documented end-to-end in `mlx-swift-lm#259` for Gemma 4:
> *"Net: `stopReason == .stop`, `toolCalls == []`, tool-call text intact in the prose."*

⚠️ **Older releases used exact equality for the `gemma` row where other families used
`hasPrefix`.** Issue `mlx-swift-lm#259` identified this as one of two root causes for Gemma 4 tool
calls not being extracted, because Gemma 4's `model_type` is `"gemma4"`, not `"gemma"`.

> ✅ **FIXED — issue `mlx-swift-lm#259` closed completed on 2026-09-14.** PR #183 had already
> added the `.gemma4` inference case and current tags on 2026-05-22. PR #548 added bounded
> cross-dialect recovery and merged immediately before the issue closed.
> The source at `3cbf928` already showed the direct `.gemma4` path, but the later recovery fix makes
> the closure broader than the July source inspection.
> Keep the §7.8 check for apps pinned to an older release.
> Retain it as a regression test when changing templates
> or parsers.

The registry presets set the format explicitly where inference cannot:

```swift illustrative
static public let glm4_9b_4bit = ModelConfiguration(
    id: "mlx-community/GLM-4-9B-0414-4bit", …, toolCallFormat: .glm4)

static public let lfm2_1_2b_4bit = ModelConfiguration(
    id: "mlx-community/LFM2-1.2B-4bit", …, toolCallFormat: .lfm2)

static public let lfm2_8b_a1b_3bit_mlx = ModelConfiguration(
    id: "mlx-community/LFM2-8B-A1B-3bit-MLX", defaultPrompt: "", toolCallFormat: .lfm2)
```

> ✅ **VERIFIED** — `LLMRegistry` statics in `Libraries/MLXLLM/LLMModelFactory.swift`.

**Which is the actionable point: if you load a model by bare Hugging Face id rather than a
registry preset, you get `toolCallFormat: nil` unless `infer` happens to know your `model_type`.**

### 7.6 `ToolCallProcessor` — the streaming state machine

```swift prelude:guide-context
public class ToolCallProcessor {
    public enum Output: Sendable, Equatable {
        case response(String)
        case toolCall(ToolCall)
    }
    public var toolCalls: [ToolCall] = []
    public init(format: ToolCallFormat = .json, tools: [[String: any Sendable]]? = nil)

    public func processChunk(_ chunk: String) -> String?          // displayable text, or nil
    public func processChunkOutputs(_ chunk: String) -> [Output]  // ordered API
    public func drainToolCalls() -> [ToolCall]
    public func processEOS()
    public func processEOS(returnBufferedText: Bool = true) -> String?
    public func processEOSOutputs() -> [Output]
}
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Tool/ToolCallProcessor.swift` (856 lines; public
> surface plus the first 140 lines read).

Internals, from doc comments and symbol names: a **four-state machine** (`normal`,
`potentialToolCall`, `collectingToolCall`, `collectingJSONToolCall`), a **bare-JSON fallback
enabled only for `.json`** (`supportsBareJSONFallback = format == .json`, with
`maxJSONFallbackBufferLength = 32_768`), de-duplication by `emittedToolCallIDs`, and per-format
EOS handling for Mistral and LFM2.

> 🟡 **RECONSTRUCTED** — the state names, the fallback constants and the dedupe mechanism are read
> from symbol names and doc comments; **`ToolCallProcessor.swift` lines 140-856 were not read line
> by line**. Treat the *existence* of these mechanisms as verified and their exact heuristics as
> unverified. See §11.3.

⚠️ **SILENT FAILURE #7 — mixing the two APIs on one processor instance.** The source carries an
explicit warning: *"Do not mix this API with `processChunk`, `processEOS`, or `drainToolCalls()` on
the same processor instance."*

The two APIs exist because the older one **loses ordering**. `processChunk` returns displayable
text and accumulates tool calls in a separate array, so if a model emits
`text → toolcall → text → toolcall`, you get all the text in one stream and all the calls in
another, with no way to reconstruct the interleaving. `processChunkOutputs` returns
`[Output]` in the order the model produced them. That ordered API arrived with PR #456
(merged 2026-07-23), which also added quote-aware JSON scanning (so `{"path": "a}b"}` no longer
terminates early) and Qwen redundant-brace recovery for `{{ …valid call… }}`.

> ✅ **VERIFIED** — source warning verbatim; PR #456 contents from the issue-mining pass.

**Use `processChunkOutputs` / `processEOSOutputs` for anything new.** The only reason to touch the
older pair is compatibility with existing code.

### 7.7 The end-to-end loop, both ways

**Way one — `toolDispatch`, the automatic loop.** `ChatSession` runs the whole cycle:

```swift prelude:external-module
struct EmptyInput: Codable {}
struct TimeOutput: Codable { let time: String }

let timeTool = Tool<EmptyInput, TimeOutput>(
    name: "get_time",
    description: "Get the current date and time including day of week.",
    parameters: []
) { _ in TimeOutput(time: "Wed Feb 18 17:50:43 PST 2026") }

let session = ChatSession(
    container, generateParameters: generateParameters,
    tools: [timeTool.schema]
) { toolCall in
    if toolCall.function.name == timeTool.name {
        return try await toolCall.execute(with: timeTool).toolResult
    }
    return "Unknown tool: \(toolCall.function.name)"
}

for try await chunk in session.streamResponse(to: "What day of week is it?") {
    print(chunk, terminator: "")
}
```

> ✅ **VERIFIED** — `Libraries/IntegrationTestHelpers/IntegrationTestHelpers.swift:260-290`,
> verbatim. This is code the maintainers run in CI.

What `ChatSession` does under the hood on a tool call, and the ordering matters:

1. Appends **`.assistant("", toolCalls: pendingToolCalls)` first**,
2. then one `.tool(result, id: toolCall.id)` per call,
3. then `continue restart` — regenerating from the top of the loop.

> ✅ **VERIFIED** — `ChatSession.swift:574-836`. Commit `19de279` explains why step 1 is not
> optional: **Gemma 4's chat template forward-scans from the assistant `tool_calls` message.**
> Omit it and the template cannot associate results with calls.

**Way two — manual, when you need to see and approve calls.** No `toolDispatch`; you drive:

```swift prelude:guide-context
let session = ChatSession(container, generateParameters: generateParameters,
                          tools: [weatherToolSchema])
var toolCalls: [ToolCall] = []
var responseText = ""
var info: GenerateCompletionInfo?

for try await generation in session.streamDetails(
    to: "What is the weather in San Francisco?", images: [], videos: []
) {
    switch generation {
    case .chunk(let text):      responseText += text
    case .toolCall(let call):   toolCalls.append(call)
    case .info(let completion): info = completion
    }
}

if !toolCalls.isEmpty {
    // Show the user what the model wants to do; get consent; execute; then:
    _ = try await session.respond(
        to: [.tool("Foggy with a high in the low 60s, clearing later in the day")])
}
```

> ✅ **VERIFIED** — `IntegrationTestHelpers.swift:209-257`, verbatim.

The manual form is what you want for anything with side effects — deleting a file, sending a
message, spending money. It is the same "tool as consent request" pattern this series records from
Apple's Foundation Models sample code (`MovePhotoToStepTool` → Yes/No UI → synthesized follow-up
turn); the shape transfers directly.

**Dispatching by name across several tools**, from Apple's sample:

```swift prelude:guide-context
func execute(_ toolCall: ToolCall) async throws -> String {
    switch toolCall.function.name {
    case currentWeatherTool.name:
        return try await toolCall.execute(with: currentWeatherTool).toolResult
    case addTool.name:
        return try await toolCall.execute(with: addTool).toolResult
    case timeTool.name:
        return try await toolCall.execute(with: timeTool).toolResult
    default:
        return "Unknown tool: \(toolCall.function.name)"
    }
}
```

> ✅ **VERIFIED** — `mlx-swift-examples/Applications/LLMEval/Services/ToolExecutor.swift`, verbatim.

⚠️ **Returning a string for an unknown tool, rather than throwing, is the right default.** A model
that hallucinates a tool name gets told so and can recover. A throw ends the turn. Note this is the
*opposite* of the Foundation Models framework's documented failure mode, where a tool named in your
instructions but absent from the toolset produces an infinite loop and no error — here, the
`default:` case is your loop breaker. Keep it.

### 7.8 When your model's format is not one of the ten

This is the case the brief for this guide asked to be answered directly, because it is common and
the library does not tell you it has happened.

**Step 1 — find out what you actually got.** Two lines, run once per model:

```swift prelude:guide-context
await container.perform { context in
    print("toolCallFormat: \(String(describing: context.configuration.toolCallFormat))")
    print("model_type    : \(context.configuration.name)")
}
```

If it prints `nil`, the loop is going to use `.json`.

**Step 2 — find out what the model actually emits.** Generate with tools attached and **print the
raw text**, not the parsed calls:

```swift prelude:guide-context
let session = ChatSession(container, generateParameters: .init(maxTokens: 256, temperature: 0),
                          tools: [myTool.schema])
var raw = ""
for try await g in session.streamDetails(to: "What's the weather in Tokyo?") {
    if let c = g.chunk { raw += c }
    if let t = g.toolCall { print("PARSED: \(t)") }
}
print("RAW OUTPUT:\n\(raw)")
```

If `PARSED:` never prints and `RAW OUTPUT` contains something that looks like a function call, you
have found your problem and you can read the format off the output.

**Step 3 — pick one of four remedies, in order of preference.**

**(a) The format is one of the ten and detection just missed it.** Set it explicitly. This is by
far the most common case:

```swift prelude:guide-context
var config = LLMRegistry.shared.configuration(id: "org/SomeModel-4bit")
config.toolCallFormat = .xmlFunction        // whichever the raw output matches
```

`ModelConfiguration.toolCallFormat` is a `var` and the load path only infers *if it was not
preset*. Because `ToolCallFormat` is `Codable` with stable raw values, you can also ship this as
app configuration rather than code.

**(b) The format is close to `.json` but not tag-delimited.** The `.json` parser has a **bare-JSON
fallback** (`supportsBareJSONFallback = format == .json`, buffer limit 32,768 characters), so a
model that emits a naked `{"name": …, "arguments": {…}}` with no `<tool_call>` wrapper is already
handled. Try `.json` before writing anything.

**(c) Write a `ToolCallParser`.** The protocol is four members (§7.3) and you already know the two
hard parts from the shipped parsers: `startTag`/`endTag` may be `nil` for inline formats, and
`parseEOS` must handle the case where your end marker is a special token that never appears as
text. Construct a `ToolCallProcessor` with it… and here you hit a limit:

> 🔴 **GAP — there is no verified public API for registering a custom `ToolCallParser` with the
> generation loop.** `ToolCallProcessor.init(format:tools:)` takes a **`ToolCallFormat` enum case**,
> not a parser instance, and `ToolCallFormat` is a closed `String`-backed enum you cannot extend.
> *What is unknown:* whether some other initializer or registry accepts a parser directly — the
> research pass read `ToolCallProcessor.swift` lines 1-140 plus a full public-symbol grep and did
> not find one. *What would resolve it:* `grep -n "ToolCallParser" Libraries/MLXLMCommon/Tool/*.swift`
> against your checkout, plus reading `ToolCallProcessor`'s remaining initializers.
> **Safe default until you have checked:** do not route a custom parser through the generation
> loop. Use remedy (d).

**(d) Parse it yourself, outside the loop.** This always works and is not much code:

```swift prelude:guide-context
// Generate with tools in the prompt but let the loop treat everything as text.
// Then parse the raw output with your own logic.
let session = ChatSession(container, generateParameters: params, tools: [myTool.schema])

var raw = ""
for try await g in session.streamDetails(to: prompt) {
    if let c = g.chunk { raw += c }
}

if let call = myCustomParse(raw) {                      // your parser
    let result = try await call.execute(with: myTool).toolResult
    _ = try await session.respond(to: [.tool(result, id: call.id)])
}
```

You lose streaming-time detection (you see the call only at end of turn) and you must supply
`Chat.Message.assistant("", toolCalls: [call])` yourself if your model's template needs it (§7.7,
step 1 — Gemma 4 does). In exchange you own the parse completely.

**(e) Change models.** Not a joke. If tool calling is central to your feature, a model whose format
is on the supported list and whose registry preset sets `toolCallFormat` explicitly — LFM2, GLM-4,
Mistral 3, Nemotron, Qwen3.5 — will cost you far less than maintaining a parser.

### 7.9 What leaks in from the Foundation Models bridge

If you are also driving this model through `LanguageModelSession` via `MLXFoundationModels`, three
tool-calling defects are worth knowing because they are *not* in the layers above:

- **Nested `@Generable` types in tool arguments used to hard-fail.** Any `Tool` whose `Arguments`
  contained a nested `@Generable` type failed at the first tool-calling turn with
  `constraintCompilationFailed("… json_schema_converter.cc:957: Check failed: … Cannot find field
  $defs …")`. Root cause: `GenerationSchema` emits `$defs` plus a root-anchored `"$ref":
  "#/$defs/Traveler"`, the envelope buries the `$defs` inside `arguments`, and **xgrammar resolves
  JSON Pointers from the document root** → dangling ref. *"Flat tools (only primitive fields) work,
  which is presumably why this hasn't surfaced — demo-sized tools don't produce `$defs`."*
  **Fixed** in PR #434 (merged 2026-07-22).
- **`.toolCalling` on a VLM-loaded model was a process-killing abort** —
  `Fatal error: SmallVector out of range` at `mlx-c/mlx/c/array.cpp:335`. The tool-calling path
  hand-built `LMInput(tokens: MLXArray(toolAwareTokens))`, a **1-D `[N]`** array; every VLM
  `prepare` indexes `dim(1)`. A second defect in the same path silently dropped image content from
  tool-calling prompts. **Fixed** in PR #435 (merged 2026-07-17) by routing through
  `context.processor.prepare(UserInput(chat:tools:additionalContext:))`.
- **Before PR #456 (merged 2026-07-23) a session could issue at most one tool call.** Multi-round
  replay, `ToolCallingModeResolution` (automatic / required / disallowed), and ordered streaming at
  parse boundaries all arrived in that ~3,200-line PR.

> ✅ **VERIFIED** — `mlx-swift-lm` issues #432/#433/#441 and PRs #434/#435/#456, from the July 2026
> issue-mining pass. All three PRs are **merged**; the fixes are in `main` but **not in the 3.31.4
> release** (2026-06-30), so a released-version pin does not have them.

That last sentence generalises: **3.31.4 shipped 2026-06-30 and `main` has moved substantially
past it.** Several fixes this guide describes — #434, #435, #439, #455, #456, #464 — landed in
July. If you pin `.upToNextMajor(from: "3.31.3")`, SwiftPM will resolve the newest 3.x tag, which
may still predate them.

---

## 8. KV cache: eight types, one contract

This is the section everything else depends on. Every performance question, every "why does
speculative decoding refuse to run", and both of §9's bugs trace back to **which cache class got
constructed and what contract it honours.**

### 8.1 The protocol

```swift illustrative
public enum RoPEOffset { case scalar(Int); case batch(MLXArray) }

public protocol KVCache: Evaluatable {
    var offset: Int { get }
    var ropeOffset: RoPEOffset { get }                    // default .scalar(offset)
    var maxSize: Int? { get }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray)
    var state: [MLXArray] { get set }
    var metaState: [String] { get set }
    var isTrimmable: Bool { get }
    @discardableResult func trim(_ n: Int) -> Int
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool)
        -> MLXFast.ScaledDotProductAttentionMaskMode
    func copy() -> any KVCache
    func prepare(lengths: [Int]?)
    func prepare(lengths: MLXArray?)
    func finalize()
}

public func withPreparedCache<Result>(_ cache: [any KVCache], lengths: [Int]?,
                                      _ body: () throws -> Result) rethrows -> Result
```

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/KVCache.swift` (2,110 lines).

**`KVCache` is a protocol whose conformers are classes** — `open class BaseKVCache: KVCache` is the
shared base. That is a deliberate choice with a real cost, and §9.1 is that cost coming due: a
`[KVCache]` array is a *value*, and its elements are *references*. Replacing an element does not
mutate the object; mutating the object does not replace the element. Both operations exist and
they mean different things.

⚠️ **`open var ropeOffset` is declared on the class, not only on the protocol extension** — commit
`616cae2`. This looks like style; it is a correctness fix. If it were declared only in a protocol
extension, a subclass override would be **statically shadowed and silently ignored** when accessed
through a `KVCache` existential. That is a Swift-specific footgun with no Python analogue, and it
is worth remembering when you subclass anything in this file.

### 8.2 The eight concrete caches, mapped to Python

| # | Swift class | Python counterpart | What it is for | Trimmable? |
|---|---|---|---|---|
| 1 | `KVCacheSimple` (alias `StandardKVCache`) | `KVCache` | **the default.** Growable buffer, `public var step = 256` | ✅ |
| 2 | `RotatingKVCache` | `RotatingKVCache` | ring buffer; `init(maxSize:keep:step:)`, `keep` default 0, `step` default 256 | **only while `offset < maxSize`** |
| 3 | `QuantizedKVCache` | `QuantizedKVCache` | packed data + scales + biases; `init(groupSize: 64, bits: 8, mode: .affine)` | ✅ |
| 4 | `ChunkedKVCache: KVCacheSimple` | `ChunkedKVCache` | `init(chunkSize:)`, `maybeTrimFront()` | ✅ |
| 5 | `ArraysCache` | `ArraysCache` | generic slot list for SSM / linear-attention state; `init(size:leftPadding:)` | ❌ |
| 6 | `MambaCache: ArraysCache` | *(folded into `ArraysCache` in Python)* | `init(leftPadding:)` | ❌ |
| 7 | `CacheList` | `CacheList` | composite for hybrid stacks; `init(_ caches: KVCache...)` | `all(...)` |
| 8 | `TurboQuantKVCache` | **none** | Swift-only asymmetric key/value quantization; `TurboQuantKVCache.swift` (1,765 lines) + `TurboQuantKernels.swift` (2,367 lines) | 🔴 unverified |

> ✅ **VERIFIED** — Swift class list from `Libraries/MLXLMCommon/KVCache.swift`. The count of eight
> is independently corroborated by the **serialization class-name table** (§8.6), which writes
> exactly eight names: `"KVCache"` (for `KVCacheSimple`), `"RotatingKVCache"`, `"QuantizedKVCache"`,
> `"ChunkedKVCache"`, `"ArraysCache"`, `"MambaCache"`, `"CacheList"`, `"TurboQuantKVCache"`.
> Python counterparts from `mlx_lm/models/cache.py` as documented in
> [Part 12 guide 04 §4.1](../../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md).

**Three Python classes have no Swift counterpart**, and their absence is load-bearing:

| Python class | Swift | Consequence |
|---|---|---|
| `ConcatenateKVCache` | — | no naive concatenate cache to trip over; Swift's simplest cache already preallocates in 256-token blocks |
| `BatchKVCache` | — | **no batched generation in MLX Swift** |
| `BatchRotatingKVCache` | — | same |

**There is no `batch_generate` in MLX Swift.** Python's continuous-batching server story
(`BatchGenerator`, left-padded decode, right-padded prefill) has no Swift equivalent at all. If you
need to serve many concurrent conversations from one Swift process, your options are: many
`ChatSession`s against one `ModelContainer` (which works — the container permits concurrent access
to already-evaluated weights and serialises only prefill), or `mlx_lm.server` in a sidecar. **The
first is the supported path and it is not the same thing as batching**: you get concurrency, not
throughput amplification, because each sequence still does its own decode step.

> ✅ **VERIFIED** — absence confirmed by the class inventory and by the concurrency design comment
> at `ModelContainer.swift:191-197`. The `SerialAccessContainer` rationale (`SerialAccessContainer.swift:39-43`)
> says it plainly: *"Unlike an `actor`, this will guarantee exclusive access for the duration of
> the async call. This is important for things like `ModelContainer` that have to perform async
> work but also need to prevent other callers for using _any_ of the internal state."*

Conversely, **`TurboQuantKVCache` has no Python counterpart** — it is a Swift-side addition, and a
substantial one (4,132 lines including its Metal kernels). §8.5 covers what it buys. Note the
maintainer's own position on it, which is worth reading before you build on it:

> ✅ **VERIFIED** — `davidkoski` on `mlx-swift-lm#294`: *"Interested, but see also: mlx-swift#405,
> mlx-swift-lm#287, #232, #160. I have a bit of a backlog I am working through. I don't know
> exactly how these turboquant PRs will land … ultimately I will have to select one of these to
> merge and it may be the one that looks the best or the one that is ready."*

`QuantizedKVCacheProtocol: KVCache` adds `groupSize`, `bits`, `mode`, `updateQuantized(keys:values:)`
and `getQuantizedState()` — that is the interface `attentionWithCacheUpdate` dispatches on.

### 8.3 The trimmability contract

Almost everything interesting depends on one question: **can this cache be rewound?**

```swift prelude:guide-context
public func canTrimPromptCache(_ cache: [KVCache]) -> Bool
@discardableResult public func trimPromptCache(_ cache: [KVCache], numTokens: Int) -> Int
```

> ✅ **VERIFIED** — `KVCache.swift`. `canTrimPromptCache` is `allSatisfy { $0.isTrimmable }`.

Three consumers need it and each breaks differently when it is absent:

1. **Speculative decoding** — rejected draft tokens must be rewound out of the main cache.
2. **Prompt-cache prefix reuse** — reusing a stored 8k prefix for a 6k prompt requires trimming to
   the common prefix.
3. **Context-window management** — dropping the oldest turns.

**Two classes are never trimmable:** `ArraysCache` and its subclass `MambaCache`. Their state is a
*running scan*, not a positional history, and **a scan cannot be un-run.** That covers Mamba, SSM,
RWKV and gated-delta / linear-attention layers, which means every hybrid 2026 architecture —
Qwen3.5, Qwen3.6, LFM2 / LFM2.5, Granite 4 hybrids, Nemotron-H, Jamba, Falcon-H1 — forfeits all
three capabilities above.

This is the same structural fact recorded elsewhere in this series on the Core AI side, where
`trimKVCache` returns `-1` whenever `extraStates` is non-empty (corrections register C5). **It is
not an MLX limitation and it is not a bug.** It is a property of the architecture, and it should
inform model selection, not just tuning.

**One class is trimmable until it isn't:** `RotatingKVCache.isTrimmable` is `offset < maxCacheSize`,
and `offset` only ever grows. So a sliding-window model is trimmable right up to the moment the
window wraps, and the transition happens **silently, mid-conversation.** That is §9.2.

⚠️ **`trimPromptCache` returns `0` rather than throwing when the cache is not trimmable.** The
`@discardableResult` annotation makes ignoring the return value a one-character omission rather
than a warning. **Check it. Every time.**

```swift prelude:guide-context
let trimmed = trimPromptCache(cache, numTokens: n)
guard trimmed == n else {
    // The rewind did NOT happen (or happened partially). You must not proceed
    // as though it did — re-prefill, or fail the operation.
    throw MyError.cacheRewindFailed(requested: n, actual: trimmed)
}
```

The Core AI side of this series records the same contract from the other direction: `trimKVCache(to:)`
returns *the actual retained prefix*, which may be `length - 1` because the last generated token's
KV lags one step, **so callers must prefill from the returned value, not the requested one**
(corrections register C5). Different framework, identical lesson: **the return value of a trim is
data, not decoration.**

### 8.4 Where the cache actually gets created

You rarely construct a cache by name. Four doors:

**(a) Implicitly, by passing `cache: nil` to `TokenIterator` or `generate`.** The model builds its
own via `newCache(parameters:)`.

**(b) `KVCacheDimensionProvider`'s default `newCache`:**

```
parameters?.maxKVSize != nil   →  RotatingKVCache(maxSize: maxKVSize, keep: 4)   per layer
otherwise                      →  KVCacheSimple()                                per layer
```

> ✅ **VERIFIED** — `LanguageModel.swift:287-302`.

⚠️ **`kvHeads.count` is the layer count.** The default `newCache` derives how many caches to build
from `kvHeads.count`, so a model that declares `public let kvHeads: [Int] = []` and never assigns
it builds **zero** caches and crashes with "Index out of range." That is not hypothetical — commit
`12d2da0` fixed exactly this in DeepSeek-V3.

⚠️ **Note the `keep: 4`.** The generic rotating cache keeps four attention-sink tokens. On the
Python side, `keep > 0` is precisely the condition that makes a `RotatingKVCache` **unquantizable**
(`NotImplementedError: Quantizing a RotatingKVCache with keep tokens is not supported`) and
unmergeable for batching. Gemma 4 escapes it in Python only because `gemma4_text.py` passes
`keep=0` explicitly.

> 🔴 **GAP — whether Swift's `RotatingKVCache` has the same `keep > 0` restriction is unverified.**
> *What is known:* Swift's `maybeQuantizeKVCache` does not convert `RotatingKVCache` **at all**
> (§8.5), so the question may be moot today. *What is unknown:* whether
> `RotatingKVCache.toQuantized()` — which exists — has a `keep` guard. *What would resolve it:*
> reading `KVCache.swift`'s `RotatingKVCache.toQuantized` body. *Safe default:* assume rotating
> caches are not quantized in Swift, because they demonstrably are not (§8.5), and do not combine
> `maxKVSize` with `kvBits` expecting both to apply.

**(c) Explicit constructors:**

```swift illustrative
public func makePromptCache(model: any LanguageModel, parameters: GenerateParameters? = nil)
    -> [KVCache]
public func makePromptCache(model: any LanguageModel, maxKVSize: Int? = nil) -> [KVCache]  // legacy
public func makePromptCacheWithLayerCount(numLayers: Int, maxKVSize: Int? = nil) -> [KVCache]
```

> ✅ **VERIFIED** — `KVCache.swift`.

`makePromptCache(model:parameters:)` is the one to use. The `maxKVSize:` overload is marked legacy;
`makePromptCacheWithLayerCount` exists for the case where you have a layer count but no model
instance (deserialization, mostly).

**(d) A model's own `newCache`.** Any model can override it, and hybrid models must — that is where
`CacheList(attentionCache, ssmCache)` gets built.

### 8.5 Quantized KV: `kvBits`, `kvScheme`, and TurboQuant

Two knobs, and the second overrides the first:

```swift illustrative
public func resolveAffineScheme(_ scheme: String?) -> (bits: Int, groupSize: Int)?
    // "affine4" -> (4, 64), "affine8" -> (8, 64)

public func maybeQuantizeKVCache(cache: inout [KVCache], kvBits: Int?, kvGroupSize: Int = 64,
                                 quantizedKVStart: Int = 0, kvScheme: String? = nil)

public func quantizedScaledDotProductAttention(
    queries:quantizedKeys:quantizedValues:scale:mask:
    groupSize: Int = 64, bits: Int = 8, mode: QuantizationMode = .affine) -> MLXArray
```

> ✅ **VERIFIED** — `KVCache.swift`.

Eligibility for conversion, per layer: the cache must be a **plain `KVCacheSimple`**, must not
already be quantized, and `cache.offset > quantizedKVStart`. The check recurses into `CacheList`
children.

⚠️ **SILENT FAILURE #8 — `kvScheme` overrides `kvBits`, and unrecognized scheme strings are
silently ignored.** Typo `"turbo8v3"` as `"turbo8v33"` and you get **no quantization and no
message**. This is a string-typed API in a language with enums; treat every scheme string as
something to validate at your own boundary:

```swift prelude:guide-context
let known: Set<String> = ["affine4", "affine8", "turbo0v4", "turbo0v3", "turbo0v2",
                          "turbo8v4", "turbo8v3", "turbo8v2", "turbo4", "turbo3", "turbo2"]
precondition(scheme.map(known.contains) ?? true, "unknown kvScheme \(scheme!)")
```

⚠️ **SILENT FAILURE #9 — `RotatingKVCache.toQuantized()` exists and is never called.** The source
carries the TODO: *"RotatingKVCache.toQuantized() is not implemented yet, like in Python."* So on
a sliding-window model (most Gemma layers), setting `kvBits` or `kvScheme` **converts nothing**.
Memory does not drop. Nothing warns. There is a one-time notice listing which layers stayed fp16 —
watch for it, because it is the only signal.

> ✅ **VERIFIED** — source TODO comment; the one-time notice is described in
> `Documentation.docc/kv-cache-quantization.md`. The Python-side manifestation is worse: there,
> `RotatingKVCache.to_quantized()` is *defined* and **raises**, so `mlx_lm.server --kv-bits N`
> starts cleanly, serves `/health` 200, and crashes on the first inference request
> (`mlx-lm#1573`/#1583). **A `hasattr` guard does not help: presence ≠ implementation.** Swift's
> "skip it silently" is less dramatic and arguably more dangerous.

**The TurboQuant scheme table**, verbatim from the package's own DocC article
(`Documentation.docc/kv-cache-quantization.md:31-43`). Naming is `turbo<K-bits>v<V-bits>`, where
`0` means keys stay fp16:

| Scheme | Keys | Values | KV compression | Character |
|---|---|---|---|---|
| `affine8` | 8-bit affine | 8-bit affine | 1.88× | near-lossless on most models, full decode speed |
| `affine4` | 4-bit affine | 4-bit affine | 3.56× | collapses on some families; validate first |
| `turbo0v4` | fp16 | 4-bit turbo | 1.58× | safest start; beats `affine8` quality on most models tested |
| `turbo0v3` | fp16 | 3-bit turbo | 1.66× | light value compression |
| `turbo0v2` | fp16 | 2-bit turbo | 1.58×† | aggressive value compression |
| `turbo8v4` | 8-bit affine | 4-bit turbo | 2.51× | conservative asymmetric |
| `turbo8v3` | 8-bit affine | 3-bit turbo | 2.75× | **recommended default** |
| `turbo8v2` | 8-bit affine | 2-bit turbo | 2.32×† | memory-bound long context |
| `turbo4` / `turbo3` / `turbo2` | turbo | turbo | up to 3.4×† | maximum compression; key sensitivity varies strongly by family |

† boundary-layer protection auto-engages: the first and last two attention layers fall back to
8-bit affine.

> ✅ **VERIFIED** — table quoted from `Libraries/MLXLMCommon/Documentation.docc/kv-cache-quantization.md:31-43`.
> **These are the package maintainers' published numbers, not Apple's, and not independently
> reproduced by this guide.**

Throughput, from the same article: *"Measured on Qwen3-1.7B (M5 Max, fp16 150 tok/s): turbo8v3 114,
turbo4 122, turbo0v4 102. Prefill stays raw fp16, so prefill throughput is unaffected."*

> Attribution: **maintainer-measured**, M5 Max, Qwen3-1.7B, published in the repo's DocC article
> at HEAD `3cbf928` (2026-07-24). Not Apple-published. No macOS build or Xcode version is stated
> in the source, so this guide cannot supply one.

Quality, same source — WikiText-2 decode-time KL divergence versus an fp16 cache:

| Model | Scheme | KLD | Note |
|---|---|---|---|
| Mistral-7B | `turbo4` | 0.040 | at 2.8× compression |
| Qwen3-1.7B | `turbo4` | 2.65 → **0.15** | with per-dimension key calibration |
| Phi-4-mini | `turbo4` | 2.76 → **0.036** | same |
| Qwen2.5-7B | `turbo4` | 0.62 → **0.060** | same |
| Phi family | `affine8` | 0.0004 | |
| Qwen2.5 | `affine8` | 0.041 | versus `turbo0v4` at 0.005 |

**Read the Qwen3-1.7B row.** `turbo4` without key calibration is a KLD of 2.65 — that is not a
subtle degradation, that is a different model. **Key sensitivity varies by family by more than an
order of magnitude, and there is no way to know which family you are in except to measure.**

**And the counter-intuitive part, from the Python side, which applies to the same kernels:**
quantized KV can **raise** peak memory during prefill. Community-measured (`mlx-lm#1587`,
Llama-3.2-3B-Instruct-4bit, M4 Max 128 GB, macOS 27.0):

| Context | Case | Peak MLX memory | Decode |
|---|---|---|---|
| 8,000 tok | fp16 | 3.46 GB | 3.2 tok/s |
| 8,000 tok | q8 | 4.87 GB (**+1.41 GB**) | 2.6 tok/s |
| 32,000 tok | fp16 | 4.72 GB | 1.0 tok/s |
| 32,000 tok | q8 | 7.10 GB (**+2.38 GB**) | 0.7 tok/s |
| 32,000 tok | q4 | 6.53 GB (**+1.81 GB**) | 0.6 tok/s |

That thread ran a pre-registered discriminator on two rigs and reached a precise conclusion: **it is
not resize churn** (presizing closed only 1.5–3.8% of the inversion); **it is the unfused quantized
attention path**, which materialises a scores tensor proportional to
`n_kv_heads × n_repeats × chunk_len × context × 4 bytes`. Predicted delta between chunk 2048 and
512: 1.208 GB; measured: 1.216 GB.

**The mitigation is a smaller prefill chunk.** At `prefill_step_size = 512` the inversion
disappeared entirely. In Swift that is `GenerateParameters(prefillStepSize: 512)`.

> Attribution: **community-measured**, `mlx-lm#1587`, two independent rigs (M4 Max 128 GB /
> macOS 27.0, and M1 MBP 16 GB), mlx-lm 0.31.3, July 2026. **Python-side measurement; the Swift
> path uses the same MLX kernels but this guide has not measured it in Swift.**

**The honest summary of `kvBits`:** it is a **capacity** lever, not a throughput lever. Paired runs
on Qwen3-32B-4bit (community-measured, `mlx-lm#1573`) show int8 KV costing **−7.4% decode at 0.5k
context, −3.1% at 4k, −2.7% at 16k**, with greedy-argmax agreement of 0.9804 → 0.9990 as context
grows. As the thread puts it: *"on a 4-bit dense model KV is only ~19% of decode-step bytes —
weights dominate, so halving KV bandwidth cannot pay for the compose/dequant overhead."*

**Use it when you need longer context in the same RAM. Do not use it hoping for speed.**

⚠️ **One family-specific hard stop:** gpt-oss uses attention sinks, and quantized SDPA does not
support them. On the Python side this manifests as a *silent client timeout* — the generation
thread dies with `'Quantized SDPA does not support attention sinks'`, the request never returns,
and it presents as a network timeout during prefill rather than an error (`mlx-lm#1438`).
**KV quantization must be off for that family.**

### 8.6 Prompt caching to disk

```swift prelude:guide-context
public func savePromptCache(url: URL, cache: [KVCache], metadata: [String: String] = [:]) throws
public func loadPromptCache(url: URL) throws -> ([KVCache], [String: String])
```

> ✅ **VERIFIED** — `KVCache.swift`.

**The wire format is Python-compatible**, which is the single most useful fact about it. Arrays are
flattened as `"i.j"`; metadata is keyed `"0.i.j"` (cache info), `"1.key"` (user metadata) and
`"2.i"` (class name). So a cache written by Swift can, in principle, be read by
`mlx_lm.cache_prompt`'s consumer and vice versa — **the class names are the shared vocabulary**,
and that is why `KVCacheSimple` is written as `"KVCache"`.

The eight names written: `"KVCache"`, `"RotatingKVCache"`, `"QuantizedKVCache"`,
`"ChunkedKVCache"`, `"ArraysCache"`, `"MambaCache"`, `"CacheList"`, `"TurboQuantKVCache"`.

One typed failure on restore: a `RotatingKVCache` whose stored `maxSize` is `"None"` throws
`KVCacheError("RotatingKVCache with maxSize=None is not supported.")`.

> 🔴 **GAP — cross-language round-tripping is untested.** *What is known:* the format is documented
> in-source as Python-compatible and the class names line up for six of eight (Swift's `MambaCache`
> and `TurboQuantKVCache` have no Python classes of those names). *What is unknown:* whether a file
> written by `mlx_lm.cache_prompt` loads in Swift and produces identical logits. *What would resolve
> it:* write a cache in each language for the same model and prompt, load in the other, compare
> next-token logits. *Safe default:* treat prompt-cache files as **same-language, same-model,
> same-quantization-settings artifacts**, exactly as the Python guide advises.

At the `ChatSession` layer:

```swift illustrative
func saveCache(to url: URL) async throws   // throws ChatSessionError.noCacheAvailable
// and a cache-accepting initializer:
ChatSession(container, cache: loadedCache, generateParameters: …)
```

⚠️ **Two traps on restore, both documented in-source.**

**(1) Do not pass `instructions` again if the cache already encodes a system prompt.** The source
warning: *"they would be re-tokenized on each call … without matching KV state, producing
incoherent output."* `ChatSession` prepends `.system(instructions)` **on every turn** when
`instructions != nil`, so a restored cache plus instructions means the system prompt is present
twice in the token stream and once in the KV — which is exactly the mismatch that produces fluent
nonsense.

**(2) `saveCache` drops `LMOutput.State`** (`mlx-swift-lm#443`, closed 2026-08-10; affected the
researched snapshot), so a restored VLM cache
has no M-RoPE deltas. §4.3.

### 8.7 Cross-turn reuse, and the `attentionWithCacheUpdate` footgun

**Reuse across turns is the highest-leverage optimisation in this whole guide**, and in
`ChatSession` you get it for free. Its internal state machine:

```swift prelude:guide-context
enum Cache {
    case empty
    case kvcache([KVCache], draftKVCache: [KVCache]?, state: LMOutput.State?)
    case history([Chat.Message])
}
```

> ✅ **VERIFIED** — `ChatSession.swift:150-158`.

Three states, and the middle one is the fast path: after the first turn the session holds a live KV
cache, and turn two prefills only the new tokens. `clear()` resets to `.empty` while keeping
`instructions`; the `history:` initializer starts in `.history` so the first generation rebuilds
from messages.

**How much is it worth?** This series records a Core AI-side, community-measured figure that is the
best available order-of-magnitude: turn-2 TTFT **23.28 s → 0.230 s (101×)** at 4k context with
byte-identical greedy output, and 15.2× at 357 tokens (qwen3-0.6b, Mac) — with the mechanism being
that trimming a KV cache is *a single integer assignment*, because attention is causal so rows at
or beyond the retained position are overwritten before any query can read them.

> Attribution: **community-measured**, from `notes/repos/john-rocky-models.md` via this series'
> corrections register (C5). **That measurement is on the Core AI runtime, not MLX Swift.** The
> *mechanism* is identical; the *number* is not transferable. Treat it as "this is worth two orders
> of magnitude, measure your own."

And the constraint that governs model selection: **linear-attention and hybrid models forfeit
prefix caching entirely and must re-prefill every turn** (§8.3).

**The footgun.** When you port or write a model, call `attentionWithCacheUpdate` and let it own the
cache:

```swift prelude:guide-context
let output = attentionWithCacheUpdate(
    queries: queries, keys: keys, values: values,
    cache: cache, scale: scale, mask: mask)
```

It routes on the cache type:

| Cache state | Route |
|---|---|
| no cache | plain `MLXFast.scaledDotProductAttention` |
| `TurboQuantKVCache`, `L > 1 && !isCompressed` | raw update + standard SDPA (**prefill stays fp16**) |
| `TurboQuantKVCache` otherwise | `compressedAttention(...)` |
| `QuantizedKVCacheProtocol` | `updateQuantized` + `quantizedScaledDotProductAttention` |
| anything else | `cache.update` + `MLXFast.scaledDotProductAttention` |

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/AttentionUtils.swift:37-95`.

⚠️ **Do not call `cache.update(...)` yourself and then pass the result to
`attentionWithCacheUpdate`.** The helper updates the cache itself, so the cache **doubles** and
attention is corrupted after the first token. This bit the codebase twice — DeepSeek V2 and
DeepSeek V3, commits `12d2da0` and `294c31f`.

### 8.8 Sizing a KV cache, and the decision rule

The formula, from the package's own wired-memory documentation:

```
elements per token per layer = 2 * kvHeads * headDim
layer bytes                  = tokens * elements per token per layer * bytesPerElement
total KV bytes               = layer bytes * numAttentionLayers
```

`bytesPerElement`: **2** for FP16/BF16, **1** for INT8, **0.5** for INT4.

> ✅ **VERIFIED** — `Documentation.docc/wired-memory.md:118-128`.

Weight bytes, if you need them for a budget:

```swift prelude:guide-context
let context = try await LLMModelFactory.shared.load(configuration: config)
let weightBytes = context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
```

> ✅ **VERIFIED** — `wired-memory.md:21-28`. Maintainer-measured deltas from the same document,
> showing how close that estimate is to reality: Qwen3-4B-Sky-High-Hermes-4bit — nbytes
> 2,262,535,712; tensor files 2,262,637,937; active-after-load 2,264,337,376.
> Qwen3-Next-80B-A3B-Instruct-MLX-4bit — 44,844,060,160 / 44,844,286,608 / 44,844,101,616.
> **Maintainer-measured, machine unstated.**

**The decision rule.** This is the table to keep:

| Your workload | Cache you want | How to get it | Watch out for |
|---|---|---|---|
| One-shot, short prompt | `KVCacheSimple` | default; pass `cache: nil` | — |
| Multi-turn chat, fits in RAM | `KVCacheSimple` **reused across turns** | `ChatSession` | mutated in place; not thread-safe |
| Long document, memory-bound | `RotatingKVCache` | `GenerateParameters(maxKVSize: N)` | loses old context; **kills trimming after wrap** (§9.2); kills KV quantization (§8.5) |
| Long shared prefix, many queries | `KVCacheSimple` + `savePromptCache` | §8.6 | model + quantization settings must match exactly; state is dropped (#443) |
| Capacity is the constraint | `QuantizedKVCache` | `kvBits: 8, quantizedKVStart: N` | peak memory can go **up**; not for rotating layers; not for gpt-oss |
| Capacity, and you have measured quality | `TurboQuantKVCache` | `kvScheme: "turbo8v3"` | Swift-only; internals unread by this guide; KLD varies 60× by family |
| Speculative decoding | `KVCacheSimple` only | §2.6 | anything non-trimmable is refused; rotating breaks **after wrap** |
| SSM / hybrid / linear-attention model | whatever `newCache` gives you | automatic | **not trimmable — plan around it** |
| Many concurrent conversations | one `ModelContainer`, many `ChatSession`s | §8.2 | this is concurrency, **not batching** |

And the negative rule, stated once so it is easy to find: **`maxKVSize` and `kvBits` together do
not do what you expect.** The rotating caches are simply not converted, so you get a bounded cache
at full precision and no message about it.

---

## 9. Two real Swift-side cache bugs

Both are open (or were open at the time of the research pass behind this guide), both are silent,
and both destroy output quality rather than crashing. They are here not as a bug list but because
each one is a **class of error** that will recur — one about value semantics, one about ignored
return values — and recognising the class is more useful than memorising the instance.

**Status of everything in this section: as of 2026-08-07**, based on a `gh`-CLI pass over
`ml-explore/mlx-swift-lm` on 2026-08-07 plus a source read at HEAD `c97539d` (2026-08-06). Re-check
before you build around either.

### 9.1 `maybeQuantizeKVCache` replaces array elements instead of mutating objects

**Issue: `mlx-swift-lm#312`. Status: still OPEN as of 2026-08-07, but the fix landed on main — PR
#453 merged 2026-08-05 (#358 closed unmerged in its favor). No release carries it: latest is 3.31.4.**

#### What happens

```swift illustrative
public func maybeQuantizeKVCache(cache: inout [KVCache], kvBits: Int?, kvGroupSize: Int = 64,
                                 quantizedKVStart: Int = 0, kvScheme: String? = nil)
```

This is called on **every step** inside `TokenIterator`'s generation loop, from `step(previous:)`
(§4.4). When `cache.offset` crosses `quantizedKVStart` mid-generation, it converts eligible
`KVCacheSimple` instances into `QuantizedKVCache` instances — by **assigning into the array**:

> ✅ **VERIFIED** — `mlx-swift-lm#312`, quoted verbatim from the issue body:
>
> > "`maybeQuantizeKVCache` is called on every step inside `TokenIterator`'s generation loop. When
> > the `quantizedKVStart` threshold is crossed mid-generation, it replaces elements in
> > `TokenIterator`'s local copy of the cache array with new `QuantizedKVCache` instances. Because
> > the function takes `cache: inout [KVCache]`, it **replaces array elements rather than mutating
> > the cache objects in place**. The caller's array (in `ChatSession`) still holds the original
> > `KVCacheSimple` references … **The model loses all context generated after the quantization
> > threshold.**"

#### Why it is a Swift bug and not a Python bug

Here is the Python line that does the same thing, from `mlx_lm/generate.py`:

```python
for e, c in enumerate(prompt_cache):
    if hasattr(c, "to_quantized") and c.offset >= quantized_kv_start:
        prompt_cache[e] = c.to_quantized(group_size=..., bits=...)
```

**It is the same element replacement.** It is safe in Python **only because a Python list is a
reference type and every holder shares one list object.** `ChatSession`'s equivalent in Python
would see the mutation because there is no "caller's copy" — there is one list.

Swift's `[KVCache]` is a **value**. `inout` gives the callee a copy-in/copy-out of *that value*, so
the assignment writes into `TokenIterator`'s own array. `ChatSession`'s array is a different value
holding the same *object references* — which are unchanged, because the objects were never mutated.
The quantized caches receive every subsequent update; the caches `ChatSession` holds receive none.
The model then generates against a KV cache that stopped growing at the threshold.

**The observable symptom** is the nastiest kind: generation continues, output stays fluent, and the
model behaves as though everything after the threshold token never happened. In a long chat, that
looks like the model "forgetting the middle of the conversation" — which is exactly what people
expect a small model to do, so it does not get reported as a bug.

#### The secondary defect in the same function

The issue also identifies dead code: the guard `!(firstQuantizable is QuantizedKVCache)` can never
be false, because the candidate came from `cache.first(where: { $0 is KVCacheSimple })` and
`QuantizedKVCache` inherits from `BaseKVCache`, **not** from `KVCacheSimple`. So the
already-quantized check does nothing. (The line number quoted in the issue is `Evaluate.swift:1806`;
**line numbers from issue bodies drift** — verify against your checkout.)

#### The maintainer's proposed fix, and why it is the right shape

> ✅ **VERIFIED** — `davidkoski` on `#312`:
>
> ```swift
> class KVCacheBox : KVCache {
>     var implementation: KVCache
>     // forwards
> }
> ```
>
> > "I think making a box type like this is probably the way to go — it will give us the most
> > flexibility in terms of having behavior over the full KVCache and let us fix this problem. …
> > I do think that a higher level type that represents the collection of `KVCache` instances might
> > be better. It would be nice to call it `KVCache` but that name is taken for the per-layer ones.
> > The drawback: it doesn't match the python plain-list implementation."

A box is a **reference-typed indirection whose identity is stable across implementation swaps**.
Swapping `box.implementation` mutates something every holder can see, because they all hold the
same box. That is the general remedy for this whole class of error, and the last sentence of the
quote names its cost: the Swift design would then diverge from the Python one, which makes ports
harder in exactly the way that produced the bug.

#### The class of error: *"port the line, lose the semantics"*

Write it down, because it will recur every time this stack is ported:

> **In a reference-semantics language, mutating a container and mutating its contents are the same
> operation. In a value-semantics language they are different operations that look identical at
> the call site.**

Three places to look for the same shape:

1. **Any `inout [SomeClass]` parameter** that replaces elements. If any caller kept its own copy of
   the array, that caller is stale.
2. **Any `struct` holding a `[SomeClass]`** that is passed by value into a generation loop. Swift's
   `TokenIterator` *is* a struct.
3. **Any Python `list[...]` translated to a Swift `Array<...>` in a port**, where the Python code
   mutates the list itself rather than its elements.

**The mitigation on any released version — 3.31.4 and earlier all predate PR #453's merge:** do not
use mid-generation KV quantization together with a caller-held cache.

```swift prelude:guide-context
// SAFE: quantization threshold is never crossed mid-generation, because the whole
// cache is quantized from token 0 or never.
let params = GenerateParameters(kvBits: 8, quantizedKVStart: 0)

// ALSO SAFE: no KV quantization at all.
let params = GenerateParameters()          // kvBits nil

// EXPOSED: crossing the threshold partway through a generation that reuses a
// caller-held cache (ChatSession, or your own [KVCache] passed to generate).
let params = GenerateParameters(kvBits: 8, quantizedKVStart: 4096)
```

⚠️ **Note the trade-off you are making with `quantizedKVStart: 0`.** The Python side measured
(`mlx-lm#1566`, M4 Pro 24 GB, mlx 0.32.0, community-measured) that quantizing from token 0 costs
**−17.1% decode** on Qwen2.5-0.5B-Instruct-4bit at a 512-token prompt, versus parity at
`start=5000`. Past the threshold the sign flips: at a 5,120-token prompt, `start=5000` gave
**+3.7%** on that model and **+18.3%** on Llama-3.2-1B-4bit. So `quantizedKVStart: 0` is the safe
setting and the slow one for short prompts. **Pick it deliberately.**

Also worth knowing: **the library default and the CLI default disagree** on the Python side —
`generate_step()` defaults `quantized_kv_start=0` while the CLIs default to 5000. Swift's
`GenerateParameters` default is **`0`**, matching the Python *library*. Whatever you were used to
from the command line is not what you get from the API.

### 9.2 `SpeculativeTokenIterator` discards `trimPromptCache`'s return value

**Issue: `mlx-swift-lm#424`. Status: OPEN as of 2026-07-29 (one comment, no maintainer fix).**

#### What happens

`RotatingKVCache.isTrimmable` is `offset < maxCacheSize`, and `offset` only ever grows. So a
sliding-window cache is trimmable up until the window wraps, and then permanently is not.

`trimPromptCache` guards on `canTrimPromptCache`, which is `allSatisfy { $0.isTrimmable }` — a
**whole-array** predicate. So **one wrapped sliding layer makes the entire rollback a no-op**, and
because the function returns `0` rather than throwing, and is annotated `@discardableResult`, a
caller that ignores the value cannot tell.

`SpeculativeTokenIterator.speculateRound()` is such a caller:

> ✅ **VERIFIED** — `mlx-swift-lm#424`, quoted from the issue body:
>
> > "`SpeculativeTokenIterator.speculateRound()` rewinds rejected drafts with
> > `trimPromptCache(mainCache, numTokens: numDraft - accepted)` **and discards the result**.
> > `trimPromptCache` guards on `canTrimPromptCache` = `allSatisfy { $0.isTrimmable }`, so **once
> > one sliding layer wraps the whole rollback returns 0 silently** and generation continues on a
> > transcript containing tokens that were never emitted. On Gemma-family models the sliding window
> > is small (e.g. 512), so a single long reply is enough. `MTPSpeculativeTokenIterator` already
> > trims by the amount actually reported."

Read the consequence twice: **generation continues on a transcript containing tokens that were
never emitted.** The rejected draft tokens are still in the KV cache. The model attends to them.
The user never saw them. Every subsequent token is conditioned on text that does not exist.

#### Three compounding effects

The same issue records two more:

**(2) Prefix reuse degrades to full re-prefill post-wrap.** Once `isTrimmable` is false, the
prompt-cache path cannot trim to a common prefix, so it re-prefills. Silent, and it looks like a
performance regression with no cause.

**(3) `RotatingKVCache.trim()` does not self-guard.** Called *directly* on a wrapped buffer — as
opposed to through `trimPromptCache` — *"it still decrements `offset`/`idx` and returns nonzero,
corrupting the circular-buffer mapping."* So the safe-looking path (check the return value!) is
unsafe if you bypass the array-level guard. **Use `trimPromptCache`, check its return, and never
call `cache.trim(_:)` on a rotating cache directly.**

**And a fourth, cross-cutting, contributed in-thread by `NivDvir`:** for M-RoPE VLMs
(Qwen2-VL, Qwen2.5-VL) decode positions are `cacheOffset + ropeDeltas`, so **the no-op rollback
also inflates the offset and generates at drifted positions** — silent, and only after the wrap.

> ✅ **VERIFIED** — all four from `#424`'s body and comments.

#### The class of error: *"a return value that reports partial success"*

> **A function that returns "how much of what you asked for actually happened" is not optional to
> check. `@discardableResult` on such a function is a loaded gun.**

The signature is `@discardableResult public func trimPromptCache(_ cache: [KVCache],
numTokens: Int) -> Int`. It reports the actual trim. Ignoring it converts "I could not do that"
into "I did that."

This series has now recorded the identical contract in three places on three different stacks:

| Stack | API | What it returns on failure | Consequence of ignoring |
|---|---|---|---|
| MLX Swift | `trimPromptCache(_:numTokens:)` | `0` | spec-decode transcript corruption (#424) |
| mlx-lm (Python) | `trim_prompt_cache(cache, n)` | `0` | server prefix reuse returns mismatched KV (`mlx-lm#1494`) |
| Core AI | `trimKVCache(to:)` | `-1` when `extraStates` is non-empty; otherwise **the actual retained prefix**, which may be `length - 1` | prefill from the wrong offset (this series' corrections register, C5) |

The Core AI row is the sharpest statement of the rule: the API returns the actual retained prefix,
**and callers must prefill from the returned value, not the requested one**, because the last
generated token's KV lags one step. Same lesson, three frameworks.

#### The mitigation you can apply today

**Check the return, and treat a shortfall as a hard failure of the operation:**

```swift prelude:guide-context
func rewind(_ cache: [KVCache], by n: Int) throws {
    guard n > 0 else { return }
    guard canTrimPromptCache(cache) else {
        throw CacheError.notTrimmable          // fail before you try
    }
    let actual = trimPromptCache(cache, numTokens: n)
    guard actual == n else {
        throw CacheError.partialTrim(requested: n, actual: actual)
    }
}
```

**And avoid the configuration that triggers it.** Speculative decoding plus a sliding-window model
is the combination at risk. Concretely:

- **Do not combine `GenerateParameters(maxKVSize:)` with speculative decoding.** `maxKVSize` is
  what makes the default `newCache` build `RotatingKVCache` for every layer.
- **Be careful with Gemma-family models specifically**, because their sliding windows are small
  (the issue names 512) and *they use rotating caches whether or not you asked for one* — the
  architecture's own `newCache` builds them. *"A single long reply is enough."*
- **Prefer MTP over draft-model speculation on such models** if you must speculate:
  `MTPSpeculativeTokenIterator` **already trims by the amount actually reported**, per the issue.

> 🔴 **GAP — the exact accept/reject and rollback arithmetic in `SpeculativeTokenIterator` is
> unverified.** *What is unknown:* how `numDraftTokens` interacts with `maxTokens`, how bonus
> tokens are handled, and whether any other call site in that iterator ignores a trim result.
> *Why:* `Evaluate.swift:864-1069` was not read in the research pass. *What would resolve it:*
> reading that range. *Safe default:* the mitigations above do not depend on those details — they
> avoid the configuration entirely.

### 9.3 A third, for the same shelf: `MLX.compile()` and `KVCacheSimple`

Not required by the brief, but it belongs next to the other two because it is the third member of
the family "Swift's type system makes a Python idiom unsound."

**Issue: `mlx-swift-lm#406`. Status: OPEN as of 2026-07-29 (zero comments).**

```swift prelude:guide-context
let previous = self.offset          // Swift Int → baked as a constant in the compiled graph
self.offset += keys.dim(2)
self.keys?[.ellipsis, previous ..< self.offset, 0...] = keys
let returnedKeys = self.keys![.ellipsis, ..<self.offset, 0...]
```

`innerState()` does not include `offset`, and slice indices derived from a Swift `Int` **are not
graph nodes**. With `shapeless: false`, recompilation triggers on input *array shape* changes, not
on integer-constant changes. Result: the write position is frozen at the trace-time offset and the
attention window is frozen with it.

Observed, on Qwen2.5-7B-Instruct-4bit greedy: **uncompiled produced 42 tokens then EOS; compiled
produced 64 tokens with a 4-token repeating cycle** (`3535, 11, 432, 4977, 1075, 11, 432, 4977,
1075, …`).

> ✅ **VERIFIED** — `mlx-swift-lm#406`, body and quoted repro.

**The lesson:** an integer that lives in Swift and controls an MLX slice is invisible to the
compiler. It is the same shape as §9.1 — **state that one layer thinks it owns and another layer
cannot see** — expressed against the graph compiler instead of against value semantics.

**Safe default: do not `MLX.compile()` a decode step that uses `KVCacheSimple`.** The suggested
fixes in-thread (a graph-traceable `MLXArray` offset, a functional cache step, or a dedicated
compile-friendly cache type) are all library changes, not caller-side workarounds.

### 9.4 How to detect all three in your own app

A single diagnostic, run against your actual configuration, catches every one:

```swift illustrative
/// Run once at startup, in DEBUG, with your real GenerateParameters.
func auditCacheConfiguration(container: ModelContainer,
                             parameters: GenerateParameters) async {
    await container.perform { context in
        let cache = makePromptCache(model: context.model, parameters: parameters)

        let classes = cache.map { String(describing: type(of: $0)) }
        let histogram = Dictionary(grouping: classes, by: { $0 }).mapValues(\.count)
        print("cache layers: \(histogram)")

        // (1) §9.2 — will speculative rollback and prefix reuse work?
        print("canTrimPromptCache: \(canTrimPromptCache(cache))")
        if !canTrimPromptCache(cache) {
            print("  ⚠️  no rollback, no prefix reuse: do not use speculative decoding")
        }

        // (2) §9.2 — do we have rotating layers that will *stop* being trimmable?
        if classes.contains(where: { $0.contains("Rotating") }) {
            print("  ⚠️  rotating layers present: trimmability is TEMPORARY (issue #424)")
            print("      maxSize per layer: \(cache.compactMap(\.maxSize))")
        }

        // (3) §9.1 — will the quantization threshold be crossed mid-generation?
        if let bits = parameters.kvBits ?? parameters.kvScheme.map({ _ in 8 }),
           parameters.quantizedKVStart > 0 {
            print("  ⚠️  kvBits \(bits) with quantizedKVStart \(parameters.quantizedKVStart)")
            print("      → mid-generation conversion; exposed to issue #312")
            print("      → use quantizedKVStart: 0, or disable KV quantization")
        }

        // (4) §8.5 — will quantization actually apply to these layers?
        let quantizable = classes.filter { $0.contains("KVCacheSimple") }.count
        if parameters.kvBits != nil || parameters.kvScheme != nil {
            print("  quantizable layers: \(quantizable)/\(cache.count)")
            if quantizable < cache.count {
                print("      ⚠️  \(cache.count - quantizable) layers will stay fp16 silently")
            }
        }
    }
}
```

> This diagnostic is composed from verified APIs — `makePromptCache(model:parameters:)`,
> `canTrimPromptCache(_:)`, `KVCache.maxSize`, `GenerateParameters` fields — all ✅ VERIFIED as
> cited in §8. The **assembly** is this guide's, not shipped code. `String(describing:
> type(of:))` on a class instance is the pragmatic way to get the concrete cache class out of a
> `[KVCache]` of existentials.

**What good output looks like** for a dense text model with no KV quantization:

```
cache layers: ["KVCacheSimple": 36]
canTrimPromptCache: true
```

**What "you are exposed" looks like** for Gemma 4 with `maxKVSize` set:

```
cache layers: ["RotatingKVCache": 36]
canTrimPromptCache: true
  ⚠️  rotating layers present: trimmability is TEMPORARY (issue #424)
      maxSize per layer: [1024, 1024, 1024, …]
  quantizable layers: 0/36
      ⚠️  36 layers will stay fp16 silently
```

Note that `canTrimPromptCache` says `true` in that second case — **because the window has not
wrapped yet.** That is the whole problem in one line of output.

---

## 10. `MLXEmbedders`

A local RAG pipeline in Swift needs two models in one process: an **embedder** to turn documents and
queries into vectors, and an **LLM** to answer over the retrieved passages. `MLXEmbedders` is the
first half, it ships in the same package, and it deliberately mirrors the LLM API shape — which
means most of §2 through §9 transfers.

### 10.1 The types

```swift illustrative
public protocol EmbeddingModel: BaseLanguageModel {
    var vocabularySize: Int { get }
    var poolingStrategy: Pooling.Strategy? { get }     // default nil
    var maxPositionEmbeddings: Int? { get }            // default nil
    func callAsFunction(_ inputs: MLXArray, positionIds: MLXArray?, tokenTypeIds: MLXArray?,
                        attentionMask: MLXArray?) -> EmbeddingModelOutput
}

public struct EmbeddingModelOutput {
    public let hiddenStates: MLXArray?
    public let pooledOutput: MLXArray?
}

public enum Pooling.Strategy: Sendable { case mean, cls, first, last, max, none }
```

> ✅ **VERIFIED** — `Libraries/MLXEmbedders/EmbeddingModel.swift`.

⚠️ **`maxPositionEmbeddings`: inputs beyond it are truncated with a warning.** Not an error — a
truncation. A 2,000-token document handed to a 512-position model becomes a 512-token document and
your retrieval quality quietly drops. **Chunk before you embed; do not rely on the model to tell
you loudly.**

`EmbedderModelContext { configuration, model, tokenizer, pooling }` and `EmbedderModelContainer`
mirror `ModelContext` / `ModelContainer` — same `perform`, same `update`, plus async
`poolingStrategy`, `modelDirectory`, `tokenizerDirectory`.

`PoolingConfiguration` decodes sentence-transformers' `1_Pooling/config.json` keys:
`word_embedding_dimension`, `pooling_mode_cls_token`, `pooling_mode_mean_tokens`,
`pooling_mode_max_tokens`, `pooling_mode_lasttoken` — **all optional** (commit `efd498b`), because
real repos ship partial files.

### 10.2 What is registered

`EmbedderTypeRegistry.shared` model types: `bert`, `roberta`, `xlm-roberta`, `distilbert`,
`nomic_bert`, `qwen3`, `lfm2`, `gemma3`, `gemma3_text`, `gemma3n`.

`EmbedderRegistry` presets: `bge_micro`, `gte_tiny`, `minilm_l6`, `snowflake_xs`, `minilm_l12`,
`bge_small`, `multilingual_e5_small`, `bge_base`, `nomic_text_v1`, `nomic_text_v1_5`, `bge_large`,
`snowflake_lg`, `bge_m3`, `mixedbread_large`, `qwen3_embedding`
(`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`), `lfm2_embedding_350m{,_4bit,_8bit}`,
`lfm2_colbert_350m{,_4bit,_8bit}`.

> ✅ **VERIFIED** — `Libraries/MLXEmbedders/ModelFactory.swift`.

Apple's `embedder-tool` defaults to `EmbedderRegistry.nomic_text_v1_5`
(`nomic-ai/nomic-embed-text-v1.5`) — a reasonable default: 768-dimensional, English, small enough
to co-reside with a 4B LLM on a phone.

### 10.3 Embedding a batch, correctly

This is the shape from Apple's `embedder-tool`, and the padding detail in it is the part people get
wrong:

```swift illustrative
return try await container.perform { context in
    let tokenizer = context.tokenizer
    let encoded = texts.enumerated().compactMap { index, text -> (Int, [Int])? in
        let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
        guard !tokens.isEmpty else { skippedIndices.append(index); return nil }
        return (index, tokens)
    }

    // [PAD] (BERT standard), EOS (autoregressive like Qwen)
    let padToken = tokenizer.convertTokenToId("[PAD]") ?? tokenizer.eosTokenId ?? 0

    let maxLength = encoded.map { $0.1.count }.max() ?? 0
    let padded = stacked(encoded.map { _, tokens in
        MLXArray(tokens + Array(repeating: padToken, count: maxLength - tokens.count))
    })
    let mask = (padded .!= padToken)
    let tokenTypes = MLXArray.zeros(like: padded)

    let outputs = context.model(
        padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)

    let poolingModule = resolvedPooler(for: context.pooling)
    let pooled = poolingModule(outputs, mask: mask,
                               normalize: self.normalize, applyLayerNorm: self.applyLayerNorm)
    pooled.eval()
    …
}
```

> ✅ **VERIFIED** — `mlx-swift-examples/Tools/embedder-tool/EmbedderRuntime+Embedding.swift`,
> verbatim; the `padToken` fallback chain arrived in commit `44b14cf`.

**Four things this encodes:**

1. **The pad-token fallback chain** — `"[PAD]"`, then EOS, then `0`. BERT-family models have a
   real `[PAD]`; autoregressive embedders like Qwen3-Embedding do not and use EOS. Getting this
   wrong does not crash; it pollutes your mean-pooled vectors with whatever token id `0` happens
   to be.
2. **The mask is derived from the pad token** (`padded .!= padToken`) and is then used **twice** —
   once as the attention mask, once by the pooler. Mean-pooling without the mask averages padding
   into every vector, and short documents get systematically worse embeddings than long ones. This
   is the classic silent RAG-quality bug.
3. **Empty inputs are skipped, with their indices recorded**, so the caller can reinsert
   placeholders. An empty token list would otherwise produce a NaN vector.
4. **`pooled.eval()` before returning across the isolation boundary** — §2.3's rule, applied.

`embedder-tool` also sanitizes vectors (NaN/Inf → 0) via
`VectorOperations.sanitize / normalize / dotProduct / hasNonFiniteValues`, and its README warns to
use **the same `--no-normalize` setting for `index` and `search`**. Cosine similarity between a
normalized and an unnormalized vector is not cosine similarity.

### 10.4 The pipeline, and the part that is actually hard

```
  documents ──chunk──▶ EmbedderModelContainer ──▶ [Float] vectors ──▶ your store
                                                                          │
  query ────────────▶ EmbedderModelContainer ──▶ [Float] ──cosine top-k──┘
                                                                          │
                          retrieved passages ──▶ Chat.Message.user(…) ──▶ ChatSession ──▶ answer
```

The retrieval half is ordinary Swift; `embedder-tool` stores a JSON `[IndexEntry]` of
`{path, embedding}` and does brute-force dot products, which is fine to a few thousand documents.

**The hard part is memory, and it is not obvious.** You now have two model weight sets resident,
plus a KV cache that grows with the retrieved context you just stuffed into the prompt. Three
concrete consequences:

**(1) Set `Memory.cacheLimit` once, globally, and low.** Every Apple sample uses 20 MB (§4.6).
The MLX buffer pool is process-wide, not per-container, and the instinct to "let it cache more
because we have two models" is wrong. The Python-side evidence for this is stark: in a churn test,
`get_peak_memory()` reported 1.00 GB while `active + cache` and the OS footprint both reported
**60.19 GB** — the pool had retained every freed buffer. Setting the cache limit to 0 in the same
test ended at **1.14 GB**.

> Attribution: **community-measured**, `mlx#3896`, M5 Max 128 GB, mlx 0.32.0, Darwin 25.4.0,
> July 2026. Python-side; the allocator is shared C++ so the mechanism applies to Swift.
> **Actionable corollary for Swift:** `Memory.snapshot()` gives you `activeMemory`, `cacheMemory`
> and `peakMemory` separately — **gate memory-pressure logic on `activeMemory + cacheMemory`**, not
> on `peakMemory`.
> Closure context (mlx#3896 closed 2026-08-08; checked 2026-08-23): the maintainer closed it by
> scoping the counter — peak memory is meant for measuring a *single* model's inference or training
> run with near-100% cache hits; for anything long-running he recommends the `active + cache` check
> himself. A two-model RAG app is exactly the shape that scoping excludes.

**(2) Load the embedder lazily and consider unloading it.** Embedding is bursty (index once, query
occasionally); generation is sustained. Holding a 350 MB embedder resident for the 99% of the time
you are generating is a poor trade on a phone. `NSCache<NSString, ModelContainer>` — the idiom in
`MLXChatExample` — works here precisely because it lets the OS evict under pressure:

```swift prelude:guide-context
private let modelCache = NSCache<NSString, ModelContainer>()
```

> ✅ **VERIFIED** — `mlx-swift-examples/Applications/MLXChatExample/Services/MLXService.swift`.
> It works because `ModelContainer` is a class.

**(3) Retrieved context is KV context.** Ten 500-token passages is 5,000 tokens of prefill on every
query, and §8.8's formula tells you exactly what that costs in cache bytes. This is where prompt
caching (§8.6) earns its keep — **if your system prompt and tool schemas are stable, they are a
shared prefix**, and re-prefilling them per query is pure waste. Retrieved passages, being
different every query, are not.

⚠️ **And the constraint that governs model choice for the LLM half:** if you picked a hybrid or
linear-attention model (Qwen3.5, Qwen3.6, LFM2.5, Granite 4, Nemotron-H, Jamba) you have **no
prefix caching at all** (§8.3) and every query re-prefills everything. For a RAG workload with a
large stable system prompt, that is the difference between 0.2 s and 20 s to first token.
**Model architecture is a RAG design decision, not just a quality decision.**

### 10.5 Where the Foundation Models path fits

If you are on iOS 27 / macOS 27, there is a second design available: keep the retrieval in Swift
but put the *generation* behind `LanguageModelSession` via `MLXFoundationModels`, or skip MLX for
generation entirely and use `SystemLanguageModel` with `SpotlightSearchTool` for retrieval. Which
is right depends on whether you need a specific model's behaviour (MLX) or want Apple to manage
the model lifecycle (Foundation Models). That comparison is
[Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) and Part 2's Spotlight RAG guide; the only thing
this guide asserts is that **the embedder half — `MLXEmbedders` — has no Foundation Models
equivalent**, so if you want on-device dense retrieval over your own corpus you are using this
library either way.

---

## 11. Decision tables, silent-failure register, gap register

### 11.1 Which API do I want?

| I want to… | Use |
|---|---|
| Stream a chat reply into a SwiftUI label | `ChatSession.streamResponse(to:)` |
| …and also show tokens/sec or catch tool calls | `ChatSession.streamDetails(to:)` |
| One-shot completion, no conversation state | `MLXLMCommon.generate(input:parameters:context:)` inside `perform` |
| Supply my own KV cache | the free `generate(input:cache:parameters:context:…)` — the container convenience has no `cache:` |
| Observe when generation truly finishes | `generateTask(...)`, then `task.cancel(); await task.value` |
| Raw token IDs (custom detokenizer, logprobs, telemetry) | `generateTokens(...)` / `generateTokensTask(...)` |
| Measure TTFT | build the `TokenIterator` yourself; the clock starts before `init` |
| Custom sampling or a custom stop rule | `TokenIterator(input:model:cache:state:processor:sampler:prefillStepSize:maxTokens:)` — note it disables KV quantization |
| Custom decoding strategy end to end | conform to `TokenIteratorProtocol`, hand it to `generateTask` |
| Run a tool loop automatically | `ChatSession(…, tools:) { toolCall in … }` |
| Approve tool calls before they run | `streamDetails`, collect `.toolCall`, then `respond(to: [.tool(result, id:)])` |
| Embed text | `EmbedderModelFactory.shared.loadContainer(...)` + `EmbedderModelContainer.perform` |
| Serve many conversations | many `ChatSession`s, one `ModelContainer` — **there is no batching in Swift** |

### 11.2 The silent-failure register

Nine, collected. Every one of them produces plausible output or plausible behaviour, and none of
them throws.

| # | § | What silently fails | How you notice | What to do |
|---|---|---|---|---|
| 1 | §2.5 | Stream yields `.toolCall` first and **zero** `.chunk` events | a "waiting for first token" spinner never stops | drive UI state from `.info` or stream termination, never from first `.chunk` |
| 2 | §3.3 | `topP`/`topK`/`minP` are ignored at `temperature: 0`, and `topP: 1.0` / `topK: 0` are no-ops anyway | output is deterministic despite a "sampling" config | run the prompt twice; identical output ⇒ greedy |
| 3 | §4.3 | `LMOutput.State` dropped across turns ⇒ M-RoPE positions recomputed from zero | VLM grounding answers drift; turn-2 logits diverge by 0.43 max-abs vs 8.3e-07 noise floor | require releases containing #448/#475 and #443; otherwise re-prefill |
| 4 | §5.3 | A trailing empty `.assistant("")` closes the assistant turn in the template | model starts a new user turn, or emits EOS immediately | trim it — `ChatSession` does; the raw `UserInput` path does not |
| 5 | §6.4 | Chat template missing, system role dropped, `additionalContext` keys ignored | fluent output, worse instruction-following | the render-and-eyeball recipe, §6.5 |
| 6 | §7.5 | `ToolCallFormat.infer` returns `nil` ⇒ loop assumes `.json` ⇒ non-JSON calls stay in the prose | `stopReason == .stop`, `toolCalls == []`, function-call text in the UI | set `toolCallFormat:` explicitly; §7.8 |
| 7 | §7.6 | Mixing `processChunkOutputs` with `processChunk`/`processEOS`/`drainToolCalls` | duplicated or lost tool calls | pick one API per processor instance |
| 8 | §8.5 | Unrecognized `kvScheme` string ignored; `kvScheme` also overrides `kvBits` | memory does not drop, nothing says why | validate scheme strings at your own boundary |
| 9 | §8.5 | `RotatingKVCache.toQuantized()` is never invoked, so sliding-window layers stay fp16 | `maxKVSize` + `kvBits` together do nothing for those layers | watch for the one-time "layers stayed fp16" notice; don't combine them |

Plus the two §9 bugs, which are defects rather than design:

| Issue | Status 2026-08-07 | Silent symptom |
|---|---|---|
| `#312` `maybeQuantizeKVCache` replaces elements, not objects | **OPEN**; fixed on main by PR #453 (merged 2026-08-05), unreleased | model loses all context after `quantizedKVStart` |
| `#424` `trimPromptCache` return discarded in `SpeculativeTokenIterator` | **OPEN** | generation continues on a transcript containing never-emitted tokens |

### 11.3 The gap register

Everything this guide could not verify, with what would resolve it.

**G1 — `SpeculativeTokenIterator`'s body.** `Evaluate.swift:864-1069` was not read. Accept/reject
sampling details, bonus-token handling, and the `numDraftTokens` × `maxTokens` interaction are
unverified. *Resolve:* read that range. *Safe default:* §9.2's mitigations do not depend on it.

**G2 — `MTPSpeculativeTokenIterator.swift` (≈500 lines).** Sticky-passthrough triggers and the
`passthroughReason` strings are unverified — the guide asserts only that
`GenerateCompletionInfo.passthroughReason` exists and is `String?`. *Resolve:* read the file.

**G3 — `ToolCallProcessor.swift` lines 140-856.** The four state names, the bare-JSON fallback
constants and the dedupe mechanism come from symbol names and doc comments. Exact heuristics —
especially per-format EOS handling for Mistral and LFM2, and `stripProtocolSpans` semantics — are
unverified. *Resolve:* read the file.

**G4 — `TurboQuantKVCache.swift` (1,765 lines) + `TurboQuantKernels.swift` (2,367 lines).** Every
number in §8.5's scheme table is quoted from the package's DocC article, **not independently
reproduced**. Whether boundary-layer protection applies where the article says it does, and what
`turbo*` does on a rotating cache, are unverified. *Resolve:* read the files and re-run the KLD
table. *Safe default:* start at `affine8` or `turbo0v4` and measure your own model.

**G5 — registering a custom `ToolCallParser`.** No public API for it was found;
`ToolCallProcessor.init(format:tools:)` takes a closed enum case. *Resolve:*
`grep -n "ToolCallParser" Libraries/MLXLMCommon/Tool/*.swift`. *Safe default:* parse outside the
loop, §7.8(d).

**G6 — cross-language prompt-cache round-tripping.** The format is documented as
Python-compatible and six of eight class names line up, but no round trip was tested.
*Resolve:* write in each language, load in the other, compare next-token logits. *Safe default:*
same-language artifacts only.

**G7 — `RotatingKVCache`'s `keep > 0` behaviour in Swift.** Python raises
`NotImplementedError` when quantizing a rotating cache with `keep` tokens; whether Swift's
`toQuantized` has the same guard is unverified, and possibly moot since `maybeQuantizeKVCache`
never calls it. *Resolve:* read `RotatingKVCache.toQuantized`. *Safe default:* assume rotating
caches are not quantized.

**G8 — detokenizer cost.** Swift ships only `NaiveStreamingDetokenizer`; Python has three.
The throughput gap on long newline-free output is unquantified. *Resolve:* benchmark
`generateTokens` versus `generate` on ~4k tokens of newline-free output. *Safe default:* use
`generateTokens` and batch-detokenize if decode looks slow on structured output.

**G9 — issue `#259`'s status versus the code.** The issue (Gemma 4 tool calls never extracted) is
recorded **OPEN**, but the source at HEAD `3cbf928` shows both named root causes addressed — a
`.gemma4` case with correct tags and a `prefix gemma4` inference rule. *Resolve:* run §7.8's
step-2 probe against a Gemma 4 checkpoint. *Safe default:* set `toolCallFormat: .gemma4`
explicitly and verify with the probe.

**G10 — the resolved `mlx-swift` version.** `Package.resolved` is not committed to
`mlx-swift-lm`. The pin is `.upToNextMinor(from: "0.31.4")` and a commit message references
0.31.5; what SwiftPM actually resolves for you is whatever is newest in that range. *Resolve:*
`swift package show-dependencies` in your own project. **This matters more than it looks** —
several correctness fixes in §3.4 and §8.5 live in `mlx` core, and reach you through a four-hop
chain (below).

### 11.4 The four-hop fix chain

A thing worth internalising before you file a bug or wait for a fix:

```
ml-explore/mlx  ──▶  ml-explore/mlx-c  ──▶  ml-explore/mlx-swift  ──▶  mlx-swift-lm
   (C++/Metal)         (C API)               (Swift bindings)          (this package)
```

> ✅ **VERIFIED** — `davidkoski` on `mlx-swift-examples#462`: *"GitHub automatically closed this
> because the root cause is fixed. We still need that to be in an mlx build, then an mlx-c build,
> then an mlx-swift build and finally the dependencies here and mlx-swift-lm need to point to the
> new tags."*

**Four tag bumps between a merged fix and your app.** Expect lag, and when you are bisecting a
correctness problem, bisect the *chain*, not just this package. The `mlx-swift-examples#462` case is instructive:
an iPhone 16 Pro (A18) produced gibberish from every LLM on iOS 26.2/26.2.1 while iPhone 17 and
M4 Max were fine; the reporter bisected to *"2.29.1 works; main fails"* and the root cause was
upstream in mlx-swift, not in the LM library at all.

### 11.5 Consolidated gotchas

The ones that do not have a section of their own:

1. **`swift test` does not work** — `xcodebuild … -skipPackagePluginValidation`.
2. **`ModelFactoryError.noModelFactoryAvailable`** if neither `MLXLLM` nor `MLXVLM` is linked; the
   registry uses `NSClassFromString` and needs the module loaded.
3. **VLM factory is tried before LLM**; failures are swallowed and only the *last* error surfaces.
4. **`TokenIterator.init` performs prefill** and can throw; it is the expensive call.
5. **Early `break` from an `AsyncStream<Generation>` leaves work in flight** — use the `…Task`
   variants.
6. **Never call `cache.update()` before `attentionWithCacheUpdate`** — double update, corrupted
   cache. Bit DeepSeek V2 and V3.
7. **`kvHeads` must be populated per layer** — `newCache` derives the layer count from
   `kvHeads.count`.
8. **`ChatSession` is not thread-safe; `ModelContainer` is. `MLXArray` is not `Sendable`** —
   `eval()` before returning from `perform`.
9. **`ChatSession`'s default `processing` resizes images to 512×512.**
10. **`generation_config.json`'s `eos_token_id` *replaces* (not unions) the `config.json` set.**
11. **`stopStrings == nil` falls back to `extraEOSTokens`** — set `[]` to disable.
12. **`temperature` defaults to `0.6`**, not 0. Python's `make_sampler` defaults to 0.
13. **`seed` is inert at `temperature == 0`.**
14. **`ModelRegistry` is a deprecated typealias in *both* `MLXLLM` and `MLXVLM`** — ambiguous if
    you import both. Use `LLMRegistry` / `VLMRegistry`.
15. **`MTPDrafterTypeRegistry.shared` is empty at bootstrap** — `await
    Gemma4AssistantRegistration.register()` first.
16. **`SendableBox.consume()` `fatalError`s on a second call.**
17. **`MLXFoundationModels` compiles to an empty library on the 26 SDK** — consumers must
    `#if canImport(FoundationModels, _version: 2)` their own call sites, not just `@available`.
18. **`preprocessor_config.json` wins over `processor_config.json`**, and `mistral3` /
    `gemma4_unified` override the declared `processor_class`.
19. **`MLX.GPU.set(cacheLimit:)` is gone** — it is `Memory.cacheLimit` / `Memory.memoryLimit` /
    `Memory.snapshot()`.
20. **Xcode ⌘⌥R with "Debug Executable" unchecked measurably improves throughput** — Apple's own
    `LLMEval` README says so. Do not benchmark under the debugger.

> ✅ **VERIFIED** — 1–19 from the sources cited in their respective sections; 20 from
> `mlx-swift-examples/Applications/LLMEval/README.md:43`: *"You may also find that running outside
> the debugger boosts performance. You can do this in Xcode by pressing cmd-opt-r and unchecking
> 'Debug Executable'."*

### 11.6 Cross-links

- **[Part 12 guide 04](../../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md)** —
  the Python counterpart to this guide. Read §4 (nine cache classes) alongside §8 here; the two
  inventories differ in exactly the ways that matter.
- **[Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)** — putting an MLX model behind
  `LanguageModelSession` via `MLXFoundationModels`, and the structured-generation constraint
  (grammar-constrained decoding needs logits, which GPU-pipelined backends do not expose).
- **[Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md)** — why `head_dim ∈ {72, 96, 192, 256, 512}`
  silently falls back to a composed SDPA, and what padding to a supported dim costs.
- **[Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md)** — the backend decision table, and the
  known-bad-claims reference.
- **Part 13's model-loading guide** — factories, registries, `Downloader` / `TokenizerLoader`,
  the `MLXHuggingFace` macros, and conversion.

### 11.7 Sources

Everything asserted in this guide traces to one of these, read during the research pass behind it:

**`ml-explore/mlx-swift-lm` @ `3cbf928b5eb24190e8952725699ae6a3bb02824d` (2026-07-24).**
`Package.swift`; `README.md`; `CONTRIBUTING.md`;
`Libraries/MLXLMCommon/{Evaluate,ChatSession,KVCache,AttentionUtils,LanguageModel,ModelContainer,ModelFactory,ModelConfiguration,Chat,UserInput,Tokenizer,TokenizerLoader,Downloader,Load,BaseConfiguration,ReasoningConfig,SpeculativeDecoding,MTPDrafterModel,WiredMemoryPolicies}.swift`;
`Libraries/MLXLMCommon/Tool/{Tool,ToolCall,ToolCallFormat,ToolParameter,ToolCallProcessor}.swift`;
`Libraries/MLXLMCommon/Utilities/SerialAccessContainer.swift`;
`Libraries/MLXLMCommon/Documentation.docc/{using,upgrade,porting,developing,kv-cache-quantization,wired-memory}.md`;
`Libraries/MLXLLM/{LLMModelFactory,LLMModel}.swift`, `Libraries/MLXLLM/Models/Llama.swift`;
`Libraries/MLXVLM/{VLMModelFactory,VLMModel,Gemma4AssistantRegistration,MediaProcessing}.swift`,
`Libraries/MLXVLM/README.md`;
`Libraries/MLXEmbedders/{ModelFactory,EmbedderModelContainer,EmbeddingModel,Pooling}.swift`;
`Libraries/MLXHuggingFace/{Macros,FoundationModelsMacros}.swift`,
`Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`;
`Libraries/IntegrationTestHelpers/IntegrationTestHelpers.swift`;
`Tests/MLXLMTests/{TestTokenizer,ToolTests,EvalTests,ChatSessionTests,KVCacheTests}.swift`.

**`ml-explore/mlx-swift-examples` @ `378f244` (2026-06-16).**
`Applications/LLMBasic/{ChatModel,ContentView,LLMBasicApp}.swift` + README;
`Applications/MLXChatExample/{Services/MLXService,ViewModels/ChatViewModel,ChatView}.swift`;
`Applications/LLMEval/{ViewModels/LLMEvaluator,Services/ToolExecutor,Models/ToolDefinitions}.swift`
+ README; `Tools/llm-tool/{LLMTool,Chat,LoraCommands}.swift`;
`Tools/embedder-tool/EmbedderRuntime+Embedding.swift`; the 3.x migration diff in commit `357c97f`.

**Issue trackers**, `gh` CLI pass dated **2026-07-27**, `ml-explore/{mlx, mlx-lm, mlx-swift-lm,
mlx-swift-examples}`. Swift-side threads read in full or in part: `#312`, `#406`, `#424`, `#420`,
`#443`, `#450`, `#259`, `#279`, `#294`, `#221`, `#432`, `#433`, `#441`, `#466`, `#474`; PRs `#358`
(open), `#383`, `#399`, `#411`, `#415`, `#434`, `#435`, `#438`, `#439`, `#455`, `#456`, `#464`.
Python-side threads used for cross-language comparison and for numbers explicitly attributed as
community-measured: `mlx#3896`, `mlx#3897`, `mlx-lm#1280`, `#1332`, `#1438`, `#1470`, `#1494`,
`#1566`, `#1573`, `#1583`, `#1587`, `#1588`.

**Release metadata**: `mlx-swift-lm` latest release **3.31.4** (2026-06-30), prior 3.31.3
(2026-04-15); `mlx` **v0.32.0** (2026-07-07); `mlx-lm` **v0.31.3** (2026-04-22).

---

*Last verified against source: 2026-07-28. `mlx-swift-lm` `main` moves weekly and this package's
issue tracker is active; treat every "OPEN" status here as a snapshot and re-check before you build
a workaround around it.*
