# mlx-swift-lm in an app: setup, concurrency, memory, and media input

**Part 13 · MLX in Swift · Reference 01**

**Version floor: `mlx-swift-lm` 3.x — pin `.upToNextMajor(from: "3.31.3")`.** The package declares
`swift-tools-version: 6.1` and platforms `.macOS(.v14)`, `.iOS(.v17)`, `.tvOS(.v17)`,
`.visionOS(.v1)` — ✅ **VERIFIED**, read from `Package.swift:1-14` this session. Those floors are the
*library's*, and they are low. The floors that will actually bite you are higher and are three
different numbers:

- **`MLXFoundationModels` requires the macOS / iOS / visionOS 27.0 SDK** to compile at all, and its
  public API is `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`. On the 26 SDK the whole target
  compiles to an **empty library**. ✅ VERIFIED (§9).
- **Apple's own minimal sample app, `LLMBasic`, targets iOS 26.2 / macOS 26.2 and Swift 6** —
  ✅ VERIFIED from the `mlx-swift-examples` pbxproj (research note, §2.4).
- **`@Generable` — the Foundation Models macro you will use with the bridge — is 26.0.** The two
  floors are different and the repo's own README shows them nested. ✅ VERIFIED (§9.4).

⚠️ **READ THIS BEFORE YOU ADD THE DEPENDENCY.** The `main` branch of `mlx-swift-lm` is a **new major
version, 3.x**, and it broke the API. Apple's README says so in a callout, verbatim:

> The `main` branch is a _new_ major version number: 3.x. In order to decouple from tokenizer and
> downloader packages some breaking changes were introduced. See
> [upgrading documentation](https://swiftpackageindex.com/ml-explore/mlx-swift-lm/main/documentation/mlxlmcommon/upgrade)
> for detailed instructions on upgrading.

— ✅ VERIFIED, `README.md:5-8`, read from the clone at HEAD `3cbf928` (2026-07-24).

**Do not track `main`.** Pin to a version. Every tutorial, blog post and coding-agent memory written
before roughly April 2026 describes the 2.x API (`loadModelContainer(hub:configuration:)`,
`HubApi`, `perform { model, tokenizer in }`) and **none of it compiles against 3.x**. §2.6 is the
migration table.

---

## What this covers

This is the "get it into a shipping app" guide. It assumes you have decided to run a model with MLX
in Swift and now have to make it survive contact with an iPhone: a real memory budget, a real
`@MainActor`, a real photo picker, and a CI that has to build on two SDKs.

Five things, in the order they will hurt you:

- **§1–§3 — Setup.** What the nine library products are, which ones you need, and the **three
  integration styles** the package offers for tokenizers and downloaders. This is not busywork:
  3.x deliberately has *no* dependency on Hugging Face, and choosing wrong here is the single most
  common reason a first build fails.
- **§4 — Model loading.** `ModelContainer` / `ModelContext`, download with progress, exactly where
  weights land on disk, and how to ship or sideload your own weights so the app never touches the
  network.
- **§5 — Concurrency.** Why `ModelContainer` is *not* an actor, what `SendableBox` is for, why
  `MLXArray` is not `Sendable`, and which of these types you may share between tasks. The package
  ships an agent skill whose `concurrency.md` is the closest thing to an official statement; it is
  quoted here and corrected where it is stale.
- **§6 — Memory.** The longest section, and the one that decides whether your app ships. Wired
  memory policies and tickets, `Memory.cacheLimit` / `Memory.memoryLimit`, the
  `com.apple.developer.kernel.increased-memory-limit` entitlement, what jetsam looks like, and a
  production memory-governor design taken from a shipping third-party iOS app.
- **§7 — Media input for VLMs.** The processor pipeline, image and video handling, and the
  **EXIF orientation bug** that Apple fixed in their own sample on 2026-06-16 — plus the
  cross-stack finding that this is not an MLX quirk.
- **§8–§9 — SwiftUI and SDK compatibility.** Streaming tokens without dropping frames, cancellation
  that doesn't crash on backgrounding, and building against both the macOS 26 and 27 SDKs.

## What this does *not* cover

- **Porting a model architecture to Swift.** `MLXLMCommon`'s `porting.md` is 777 lines and deserves
  its own guide. Cross-referenced in §10.
- **The `MLXFoundationModels` bridge in depth** — building an `MLXLanguageModel` and handing it to
  `LanguageModelSession` is [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md). §9 covers only the
  *compilation* consequences of that target existing.
- **KV-cache tuning, quantized KV, speculative decoding.** Named here where they touch memory;
  taught in this part's cache guide.
- **LoRA training on device.** `LoRATrain` exists in `MLXLLM`; it is a separate guide.
- **The Python side.** [Part 12](../../part-12-mlx-python/README.md) — and note the Swift port has
  *different* bugs, several of which are worse.

## What you need

- **Xcode 26 or Xcode 27.** Both work; §9 explains what you lose on 26. If you want
  `MLXFoundationModels`, you need the **27.0 SDK**.
- **A device, not the simulator**, for any memory work. Every number in §6 is a device number.
- **`swift-format` 603.0.0** if you intend to contribute upstream. CI pins it; a different local
  version reformats files your PR never touched. ✅ VERIFIED, `README.md:10-11`.
- **The Metal toolchain installed.** `mlx-swift-lm`'s own CI runs
  `xcodebuild -showComponent MetalToolchain` as a precondition.
- **~5 GB of disk** for a 4-bit 4B model plus its tokenizer, and patience for the first download.

## Evidence base

Unless marked otherwise, everything here was read this session from the `mlx-swift-lm` working tree
at HEAD `3cbf928b5eb24190e8952725699ae6a3bb02824d` — *"Integration tests: build on both macOS 26 and
27 SDKs (#464)"*, authored 2026-07-24 by Charlie Le \<charlie_le@apple.com\> — plus research notes
covering `mlx-swift-examples` at HEAD `378f244` (2026-06-16), a GitHub issue/PR mining pass over the
MLX stack, and a deep read of a shipping third-party iOS app. Community sources are labelled as such
every time they appear.

---

## Contents

1. [The 3.x version warning, in full](#1-the-3x-version-warning-in-full)
2. [The package: nine products, what each is for](#2-the-package-nine-products-what-each-is-for)
3. [The three integration styles](#3-the-three-integration-styles)
4. [Model loading: containers, contexts, downloads, disk](#4-model-loading-containers-contexts-downloads-disk)
5. [Concurrency: what runs where, and what is Sendable](#5-concurrency-what-runs-where-and-what-is-sendable)
6. [Memory: the section that decides whether you ship](#6-memory-the-section-that-decides-whether-you-ship)
7. [Media input for VLMs](#7-media-input-for-vlms)
8. [SwiftUI patterns: streaming, cancellation, progress](#8-swiftui-patterns-streaming-cancellation-progress)
9. [SDK compatibility: macOS 26 and 27 in one build](#9-sdk-compatibility-macos-26-and-27-in-one-build)
10. [Failure catalogue and pre-ship checklist](#10-failure-catalogue-and-pre-ship-checklist)
11. [Sources](#11-sources)

---

## 1. The 3.x version warning, in full

### 1.1 What changed and why

`mlx-swift-lm` used to be part of `mlx-swift-examples`. It was split out in commit `0db7c5d`
(2025-11-11, *"split out mlx-swift-lm (#441)"*), and `mlx-swift-examples` now carries only apps,
CLI tools and two leftover libraries (`MLXMNIST`, `StableDiffusion`). ✅ **VERIFIED** —
`mlx-swift-examples` README, quoted in the research note:

> `MLXLMCommon`, `MLXLLM`, `MLXVLM` and `MLXEmbedders` have moved to a new repository containing
> _only_ reusable libraries: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm).
> Previous URLs and tags will continue to work, but going forward all updates to these libraries
> will be done in the other repository. Previous tags _are_ supported in the new repository.

Then 3.x happened. The upgrade document states the reason plainly (✅ VERIFIED,
`Libraries/MLXLMCommon/Documentation.docc/upgrade.md:7-20`):

> mlx-swift-lm 3.x has breaking API changes from 2.x:
>
> - Download and Tokenizers are protocols and require concrete implementations
> - MLXEmbedders now uses the same download/load infrastructure as MLXLMCommon
>
> This was done for several reasons:
>
> - break the hard dependency on the HuggingFace Hub and Tokenizer implementations
>     - this allows other implementations with other design constraints, such as performance optimizations
> - provide a mechanism to separate the download of weights and the load of weights

That second bullet is the one nobody notices and everybody needs. In 2.x, "download the model" and
"load the model" were one call. In 3.x they are separable, which is what makes it possible to ship
weights inside your app bundle, or to download them with your own `URLSession`-based engine that
supports background transfer and resume (§4.5, §6.9).

Read the upgrade document before you write any code:
<https://swiftpackageindex.com/ml-explore/mlx-swift-lm/main/documentation/mlxlmcommon/upgrade>

⚠️ If that URL 404s — and issue **#217** on the repo is literally titled *"3.31.3 release's upgrade
notes are 404'd"* (community-reported, from the issue-mining note) — read the source instead:
`Libraries/MLXLMCommon/Documentation.docc/upgrade.md` in the repo. The README anticipates exactly
this and tells you to do the same for the `using` article:

> **NOTE**
> If the documentation link shows a 404, view the
> [source](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/Documentation.docc/using.md).

✅ VERIFIED, `README.md:39-41`.

### 1.2 Pin it

```swift illustrative
// Package.swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
```

✅ **VERIFIED** — this exact line appears three times in the repo: `README.md:49`, `README.md:67`,
and `Documentation.docc/using.md:206`. `.upToNextMajor` is what Apple writes, and given that the
*whole point* of the 3.x bump was breaking changes, taking the next major automatically is exactly
what you do not want. Use `.upToNextMajor(from:)` and treat a major bump as a scheduled migration.

For reference, `mlx-swift-examples` — Apple's own consumer of this package — resolves to
**`mlx-swift-lm` 3.31.3** (revision `1c05248`) and **`mlx-swift` 0.31.4** (revision `dc43e62`) in
its committed workspace `Package.resolved`. ✅ VERIFIED from the research note's transcription of
that file. `mlx-swift-lm` itself declares
`.package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4"))`
(✅ VERIFIED, `Package.swift:99`), so the transitive MLX version moves on minor releases and you do
not get to pin it directly from your own manifest — pin `mlx-swift-lm` and let it choose.

### 1.3 swift-format is pinned to 603.0.0

> We use `swift-format` to keep the code formatting consistent. CI has this pinned to `603.0.0`
> right now.

✅ VERIFIED, `README.md:10-11`. The rationale is in the CI workflow and is worth internalising if you
plan to contribute, because it is a real failure mode rather than a style preference: the lint job
runs `pre-commit run --all` over the **whole repo**, so *"a new swift-format release can change
formatting rules and reformat files no PR touched, turning the whole-repo `pre-commit run --all` red
on every open PR at once."* ✅ VERIFIED, `.github/workflows/pull_request.yml`, quoted in the research
note.

The repo's `.swift-format` is short enough to copy if you want your own code to match:

```json
{ "version": 1,
  "indentation": { "spaces": 4 },
  "spacesAroundRangeFormationOperators": true,
  "indentConditionalCompilationBlocks": false }
```

✅ VERIFIED, `.swift-format`.

Note `"indentConditionalCompilationBlocks": false` — that is not decoration. This package is full of
`#if canImport(FoundationModels, _version: 2)` blocks at file scope (§9) and un-indented `#if` is
what keeps those readable.

### 1.4 The other tooling gotchas you will hit in the first hour

Three of these will stop your build cold and none of them produce a message that says what is wrong.

**`swift test` does not work.** Use `xcodebuild`:

```bash
xcodebuild test -scheme mlx-swift-lm-Package -destination 'platform=macOS' -skipPackagePluginValidation
```

✅ VERIFIED, `CONTRIBUTING.md:22-55`. The reason is transitive: *"mlx-swift 0.31.5 added the CudaBuild
build-tool plugin, which xcodebuild refuses to run non-interactively without this flag"* (commit
`d242429`).

**`-skipMacroValidation` is mandatory** for `xcodebuild` in any project that uses the
`MLXHuggingFace` macros, which is most projects. Xcode blocks unvalidated macro plugins; the error
looks like a signing problem. ✅ VERIFIED — `mlx-swift-examples` added it to CI for every scheme in
commit `357c97f` (research note §15, gotcha 2).

**The Metal toolchain must be installed.** `mlx-swift-lm` CI runs
`xcodebuild -showComponent MetalToolchain` as an explicit precondition step before building.
✅ VERIFIED, `.github/workflows/pull_request.yml`.

---

## 2. The package: nine products, what each is for

### 2.1 The product list

`Package.swift` declares **nine library products** — ✅ VERIFIED, read directly from
`Package.swift:15-43` this session:

| Product | What it is | Do you need it? |
|---|---|---|
| **`MLXLMCommon`** | The core. Protocols (`Downloader`, `Tokenizer`, `TokenizerLoader`, `LanguageModel`), `ModelContainer` / `ModelContext`, `ChatSession`, `Evaluate.swift`'s generation API, KV caches, tool calling, wired-memory policies. | **Always.** |
| **`MLXLLM`** | 56 text model implementations + `LLMModelFactory` + `LLMRegistry` + LoRA training. | If you run a text model. |
| **`MLXVLM`** | 17 vision-language model implementations + `VLMModelFactory` + `VLMRegistry` + `MediaProcessing`. | If you run a VLM. |
| **`MLXEmbedders`** | Encoder / embedding models, pooling, `EmbedderModelContainer`. | If you do RAG or semantic search on device. |
| **`MLXHuggingFace`** | The macros: `#hubDownloader`, `#huggingFaceTokenizerLoader`, `#huggingFaceLoadModelContainer`, `#huggingFaceLoadModel`, `#adaptHuggingFaceTokenizer`, `#huggingFaceLanguageModel`. | If you pick integration style 3 (§3.4). |
| **`MLXFoundationModels`** | The bridge to Apple's `FoundationModels`: `MLXLanguageModel` and its `Executor`. **27.0 SDK only.** | If you want `LanguageModelSession` over an MLX model. |
| **`MLXGuidedGeneration`** | Grammar-constrained generation (JSON Schema or EBNF) for any MLX model, built on a vendored xgrammar. | If you need structured output without Foundation Models. |
| **`BenchmarkHelpers`** | Shared benchmarking scaffolding. | No — internal-ish. |
| **`IntegrationTestHelpers`** | Shared integration-test model IDs, container caching, reusable test suites. | No — internal-ish. |

⚠️ **Correction to a common brief.** `MLXCXGrammar` and `MLXHuggingFaceMacros` are **targets, not
products.** ✅ VERIFIED — `Package.swift:15-43` lists nine `.library(...)` products and neither name
appears among them; `MLXCXGrammar` is declared at `Package.swift:194` as an internal target
(the vendored C++17 xgrammar) and `MLXHuggingFaceMacros` at `Package.swift:159` as a `.macro`
target. You **cannot** write `.product(name: "MLXCXGrammar", package: "mlx-swift-lm")` — SwiftPM
will tell you the product does not exist. You get `MLXCXGrammar` transitively by depending on
`MLXGuidedGeneration`, and `MLXHuggingFaceMacros` transitively by depending on `MLXHuggingFace`.

### 2.2 What the internal targets do, and why one of them matters to you

`MLXCXGrammar` vendors xgrammar (pinned to upstream release tag **`v0.1.30`**, resolved SHA
`d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505`; ✅ VERIFIED, `Libraries/MLXCXGrammar/xgrammar/VERSION`).
Its `cxxSettings` contain a detail that is a genuinely useful piece of intelligence about the wider
2026 stack (✅ VERIFIED, `Package.swift:203-228`):

```swift illustrative
cxxSettings: [
    .headerSearchPath("xgrammar/include"),
    // ...
    // Rename the vendored C++ namespaces at compile time so this
    // target's symbols cannot collide with another xgrammar in the
    // same binary (e.g. CoreAI's prebuilt copy).
    .define("xgrammar", to: "mlx_xgrammar"),
    .define("picojson", to: "mlx_picojson"),
    // ...
],
linkerSettings: [ .linkedLibrary("c++") ]
```

Read that comment again: **Apple's Core AI framework ships its own copy of xgrammar**, and
`mlx-swift-lm` renames its namespaces at compile time so the two can coexist in one binary. If you
are building an app that uses both Core AI and MLX guided generation — a perfectly reasonable thing
to do in 2026 — this is why it links. Cross-reference
[Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).

`MLXHuggingFaceMacros` is a `.macro` target depending on `SwiftSyntaxMacros` and
`SwiftCompilerPlugin`. Its presence is why `swift-syntax` shows up in your dependency graph
(`mlx-swift-examples` resolves swift-syntax **600.0.1**; ✅ VERIFIED from the research note's read of
the committed `Package.resolved`) and why `-skipMacroValidation` is needed. `mlx-swift-lm`'s own
manifest constrains it deliberately (✅ VERIFIED, `Package.swift:100-104`):

```swift illustrative
// 602.0.0 floor: swift.org publishes signed prebuilt swift-syntax artifacts only for
// >= 602 tags on current toolchains; a 600.x/601.x resolution falls back to the full
// source compile of swift-syntax.
.package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "604.0.0"),
```

That comment is worth a full minute of your attention if your CI build times matter: resolving
swift-syntax below 602 means **compiling swift-syntax from source**, which is minutes, every clean
build. If something else in your graph pins swift-syntax low, you pay for it here.

There is a live community complaint about this — issue **#339** (CLOSED),
*"MLXHuggingFace: consider a macro-free path — its macros pull swift-syntax into consumer build
graphs."* Community-reported, from the issue-mining note. Closed, not fixed. §3.2 is the macro-free
path.

### 2.3 The `FoundationModelsIntegration` trait

`Package.swift` declares one SwiftPM **trait**, and the comment on it is the clearest statement of
the package's 26-vs-27 strategy anywhere in the repo. ✅ VERIFIED, `Package.swift:44-59`, verbatim:

```swift illustrative
traits: [
    // Gates the MLXLanguageModel adapter for Apple's FoundationModels
    // framework. Default-on. Disabling the trait compiles MLXFoundationModels
    // to an empty library: the entire `MLXLanguageModel` / `MLXLanguageModel.Executor`
    // surface requires FoundationModels types that are not available on platforms
    // older than iOS/macOS/visionOS 27.0, and the MLXDownloadProgress observable
    // (whose only producer is that adapter) is gated alongside it. Consumers
    // targeting older OS versions can still use this package for MLXLLM /
    // MLXLMCommon / MLXEmbedders etc. by turning the trait off.
    .trait(
        name: "FoundationModelsIntegration",
        description:
            "Enables the MLXLanguageModel adapter for Apple's FoundationModels framework. Disabling removes the MLXLanguageModel / MLXLanguageModel.Executor types."
    ),
    .default(enabledTraits: ["FoundationModelsIntegration"]),
],
```

Practical reading: **the trait is on by default and you almost never turn it off**, because the
*SDK* check (`canImport(FoundationModels, _version: 2)`) already does the real work. Turn it off
only if you want to be certain the FM adapter is absent — for example to guarantee your binary
carries no reference to `MLXDownloadProgress`. §9 covers the interaction in full.

Note also what the trait comment tells you incidentally: **`MLXDownloadProgress` is an `@Observable`
whose only producer is the FoundationModels adapter.** If you are on the plain `ModelContainer` path
you will not see it, and you should not go looking for it — use the `progressHandler:` parameter
(§4.3) instead.

### 2.4 No Hugging Face dependency

This is the fact that trips up every first build. ✅ VERIFIED, `Package.swift:96-105`: the
`dependencies:` array contains exactly **two** entries — `mlx-swift` and `swift-syntax`. There is
**no** `swift-transformers`, **no** `swift-huggingface`, no networking library of any kind.

That is the whole point of 3.x. The package defines protocols; you supply conformances. §3 is how.

### 2.5 What lives where (target → path map)

✅ VERIFIED from `Package.swift`'s target declarations, transcribed in the research note:

| Target | Path | Depends on |
|---|---|---|
| `MLXLMCommon` | `Libraries/MLXLMCommon` | MLX, MLXNN, MLXOptimizers |
| `MLXLLM` | `Libraries/MLXLLM` | MLXLMCommon, MLX, MLXNN, MLXOptimizers |
| `MLXVLM` | `Libraries/MLXVLM` | MLXLMCommon, MLX, MLXNN, MLXOptimizers |
| `MLXEmbedders` | `Libraries/MLXEmbedders` | MLX, MLXNN, MLXLMCommon |
| `MLXHuggingFaceMacros` | `Libraries/MLXHuggingFaceMacros` | `.macro`: SwiftSyntaxMacros, SwiftCompilerPlugin |
| `MLXHuggingFace` | `Libraries/MLXHuggingFace` | MLXHuggingFaceMacros, MLXLMCommon, (trait-conditional) MLXFoundationModels |
| `MLXCXGrammar` | `Libraries/MLXCXGrammar` | vendored xgrammar, C++17 |
| `MLXGuidedGeneration` | `Libraries/MLXGuidedGeneration` | MLXLMCommon, MLXCXGrammar, MLX |
| `MLXFoundationModels` | `Libraries/MLXFoundationModels` | MLXLMCommon, (trait-conditional) MLXGuidedGeneration, MLX, MLXNN |
| `BenchmarkHelpers` | `Libraries/BenchmarkHelpers` | MLXLMCommon, MLXLLM, MLXVLM, MLXEmbedders, MLX |
| `IntegrationTestHelpers` | `Libraries/IntegrationTestHelpers` | same as BenchmarkHelpers |

`cxLanguageStandard: .cxx17` (`Package.swift:312`).

One structural consequence worth flagging now because it causes a confusing runtime error in §4.2:
**`MLXLMCommon` does not depend on `MLXLLM` or `MLXVLM`.** The dependency arrow points the other
way. That is deliberate and it is implemented with `NSClassFromString` dynamic discovery.

### 2.6 The 2.x → 3.x migration table

Everything in this table is ✅ **VERIFIED** from `upgrade.md` (the "Breaking Changes" and "Release
Notes" sections) plus the actual diff in `mlx-swift-examples` commit `357c97f`, *"mlx-swift-examples
prep for mlx-swift-lm 3.x release (#468)"*, 2026-04-16.

| 2.x | 3.x |
|---|---|
| `import Hub` | `import HuggingFace` (+ `import MLXHuggingFace` for macros) |
| `loadModelContainer(configuration:)` | `#huggingFaceLoadModelContainer(configuration:)` **or** `loadModelContainer(from:using:configuration:)` |
| `hub:` parameter (a `HubApi`) | `from:` parameter — a `URL` **or** any `Downloader` |
| `HubApi` | `HubClient` (from `swift-huggingface`) |
| `HubApi(downloadBase:)` | `HubClient(cache: HubCache(cacheDirectory:))` + `#hubDownloader(client)` |
| `loadModelContainer(directory:)` | `loadModelContainer(from: modelDirectory)` |
| `ModelFactory` (as a type) | `any ModelFactory` — it is now an existential |
| `ModelConfiguration.tokenizerId` / `.overrideTokenizer` | `tokenizerSource: TokenizerSource?` — `.id(String)` or `.directory(URL)` |
| `ModelConfiguration.preparePrompt` | **removed** — use chat templates |
| `ModelConfiguration.modelDirectory(hub:)` | **removed** — pass the `URL` directly |
| `defaultHubApi` global | **removed** — `HubClient.default` from the `HuggingFace` module |
| `loadTokenizer(configuration:hub:)` | **removed** — `AutoTokenizer.from(directory:)` |
| `replacementTokenizers` / `TokenizerReplacementRegistry` | **removed** — `AutoTokenizer.register(_:for:)` |
| `downloadModel(hub:configuration:progressHandler:)` | `Downloader.download(id:revision:matching:useLatest:progressHandler:)` |
| `ModelFactory._load(hub:configuration:progressHandler:)` | `_load(configuration: ResolvedModelConfiguration)` |
| `ModelFactory._loadContainer` | **removed** — base `loadContainer` builds from `_load` |
| `tokenizer.decode(tokens:)` | `tokenizer.decode(tokenIds:)` |
| `MLXEmbedders.ModelConfiguration.nomic_text_v1_5` | `EmbedderRegistry.nomic_text_v1_5` |
| `MLXEmbedders.loadModelContainer(hub:configuration:)` | `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)` |
| `MLXEmbedders.ModelContainer` | `EmbedderModelContainer` + `EmbedderModelContext` |
| `perform { model, tokenizer in }` | `perform { context in }` |
| `TokenIterator(prompt: MLXArray)` | `TokenIterator(input: LMInput)` |
| `ModelRegistry.llama3_2_3B_4bit` | `LLMRegistry.llama3_2_3B_4bit` (or `VLMRegistry`) |
| `generate(..., didGenerate:)` callback | `AsyncStream`-based `generate(...)` |
| `createAttentionMask(h:cache: [KVCache])` | `createAttentionMask(h:cache: KVCache?, windowSize:returnArray:)` |

⚠️ **The upgrade document itself contains stale module names.** Its "Breaking Changes → Loading API"
section says *"use the convenience methods in `MLXLMHuggingFace` / `MLXEmbeddersHuggingFace`"* and
*"`HubClient` conforms to `Downloader` via `MLXLMHuggingFace`"* (✅ VERIFIED, `upgrade.md:246-250`).
**Neither module exists.** `Package.swift`'s product list has no `MLXLMHuggingFace` and no
`MLXEmbeddersHuggingFace`; the real product is **`MLXHuggingFace`**, and `HubClient` conforms to
`Downloader` through the `#hubDownloader` macro expansion, not through a separate module. This is
the same staleness that infects the shipped agent skill (§5.6) and the per-library READMEs. Trust
`Package.swift`, the root `README.md` and `using.md`; treat everything else in the repo's prose as
possibly a release behind.


---

## 3. The three integration styles

### 3.1 The trade Apple is offering you

`using.md` states the choice directly (✅ VERIFIED,
`Libraries/MLXLMCommon/Documentation.docc/using.md:34-42`, verbatim):

> There are 3 general ways to select and use concrete Downloader and Tokenizer implementations:
>
> - implementing protocols
> - using an integration package
> - using `MLXHuggingFace` macros
>
> If you are <doc:upgrade> from mlx-swift-lm 2.x the macros will be the simplest way, but consider
> <doc:#Integration-Packages> as there are alternate implementations that may provide features and
> capabilities that you want.

And the root README frames it as a trade (✅ VERIFIED, `README.md:36`):

> This package integrates with a variety of tokenizer and downloader packages through protocol
> conformance. Users can pick from **three ways to integrate with these packages, which offer
> different tradeoffs between freedom and convenience.**

Here is the trade made concrete. The axis is *who owns the network and the tokenizer*:

| | Style 1 — protocols | Style 2 — integration package | Style 3 — macros |
|---|---|---|---|
| Dependencies you add | whatever you already use | one adapter package | `swift-huggingface` + `swift-transformers` |
| swift-syntax in your graph | no | depends | **yes** |
| Background / resumable download | **yours to build, and you can** | adapter's | `HubClient`'s behaviour, not yours |
| Ship weights in the app bundle | trivial (no `Downloader` at all) | trivial | trivial |
| Custom tokenizer (e.g. a faster one) | **yes** | maybe | no |
| Lines of code to first token | ~40 | ~10 | ~6 |
| Who to blame when it breaks | you | adapter author | macro expansion |

The honest summary: **style 3 for a prototype, style 1 for a shipping app that downloads models.**
The reason is §6.9 — a real iOS app needs `URLSessionConfiguration.background`, resume data,
cellular policy and a `BGContinuedProcessingTask`, and none of that is expressible through a
`Downloader` you did not write.

### 3.2 Style 1 — implement the protocols

There are three protocols and they are all tiny. ✅ **VERIFIED**, read from source this session.

`Libraries/MLXLMCommon/Downloader.swift:16-36`:

```swift compile:27 imports:Foundation
public protocol Downloader: Sendable {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}
```

`Libraries/MLXLMCommon/TokenizerLoader.swift` — the whole file:

```swift prelude:guide-context
public protocol TokenizerLoader: Sendable {
    func load(from directory: URL) async throws -> any Tokenizer
}
```

`Libraries/MLXLMCommon/Tokenizer.swift:6-21`:

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

Defaults in the protocol extension (`Tokenizer.swift:23-54`) supply `encode(text:)` with
`addSpecialTokens: true`, `decode(tokenIds:)` with `skipSpecialTokens: **false**`, and computed
`eosTokenId` / `unknownTokenId` via `convertTokenToId`.

⚠️ **SILENT FAILURE — `skipSpecialTokens` defaults to `false`.** The convenience
`decode(tokenIds:)` overload does *not* strip special tokens. For a reasoning model this means
`<think>` and `</think>` **render as literal text in your UI** rather than being consumed as control
tokens. This does not throw, does not warn, and looks like a model quality problem rather than a
decoding problem. The source acknowledges it obliquely via `ReasoningConfig.isSpecialToken`'s doc
comment. The fix is to call the full form with `skipSpecialTokens: true`, or to consume the
reasoning delimiters yourself using `ReasoningConfig.startDelimiter` / `.endDelimiter`. ✅ VERIFIED
from `Tokenizer.swift:23-54` and `ReasoningConfig.swift`.

`using.md` ships a complete, compiling `Downloader` conformance, which is the best possible template
because it is exactly what the macro generates. ✅ VERIFIED, `using.md:60-98`, verbatim:

```swift illustrative
import HuggingFace
import MLXLMCommon

struct HubDownloader: MLXLMCommon.Downloader {
    private let upstream: HubClient

    init(_ upstream: HubClient) {
        self.upstream = upstream
    }

    init() {
        self.upstream = HubClient()
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HuggingFaceDownloaderError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"

        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

// now you can use it
let downloader = HubDownloader()
let tokenizerLoader: any TokenizerLoader = ...

let model = try await loadModel(
    from: downloader,
    using: tokenizerLoader,
    id: "mlx-community/Qwen3-4B-4bit"
)
```

Two details in that snippet are load-bearing and easy to miss:

1. **`revision ?? "main"`.** The protocol's `revision` is optional; the *caller* is
   `ModelFactory.resolve`, which passes `configuration.id`'s revision, and `ModelConfiguration`
   defaults that to `"main"` anyway. Your conformance still has to handle `nil`.
2. **`progressHandler: { @MainActor progress in ... }`.** The inner closure is `@MainActor`-isolated
   even though the outer `progressHandler` is `@Sendable`. That is what makes it safe to hop
   straight into SwiftUI state. Do the same in your own conformance.

Your own `Downloader` gets one more thing for free: the `matching patterns:` array. The package
passes two different pattern sets depending on what it is fetching (✅ VERIFIED,
`Libraries/MLXLMCommon/ModelFactory.swift:5-7`):

```swift illustrative
package let tokenizerDownloadPatterns = ["*.json", "*.jinja"]
package let modelDownloadPatterns = ["*.safetensors"] + tokenizerDownloadPatterns
```

So a model fetch asks for `*.safetensors`, `*.json` and `*.jinja`; a *tokenizer-only* fetch (when
`ModelConfiguration.tokenizerSource` names a different repo) asks for only `*.json` and `*.jinja`.
If your downloader ignores the patterns and grabs the whole repo, you will pull `.bin` PyTorch
weights and `.gguf` files nobody wants and your first-run download will be several times larger than
it should be. Honour the patterns.

⚠️ One more trap in the same code path: when `resolve` fetches a *separate* tokenizer repo, it
passes a **no-op progress handler**. ✅ VERIFIED, `ModelFactory.swift:228-263`. So for any model
whose `tokenizerSource` is `.id(...)`, your progress UI will reach 100%, then sit there while a
second, unreported download happens. If your models use split tokenizer repos, report indeterminate
progress after the main download completes rather than showing a finished bar.

### 3.3 Style 2 — an integration package

This is the style Apple intends to grow, and today it is nearly empty. ✅ VERIFIED, `using.md:111-123`,
verbatim:

> Integration packages provide an adapter that encapsulates a concrete implementation. Adding a
> dependency on the adapter will transitively add a dependency on the implementation.
>
> So which adapter do you chose?
>
> - `huggingface/swift-transformers`
>     - this is the package that mlx-swift-lm originally integrated with
>
> **No additional integration packages are provided at this time, but feel free to contribute one!**

🔴 **GAP.** `using.md` names `huggingface/swift-transformers` as an integration package and shows a
call shape in `upgrade.md:95-108` that omits the `using:` parameter entirely:

```swift prelude:external-module
import IntegrationPackage

let model = try await loadModelContainer(
    from: HubClient(),
    configuration: modelConfiguration
)
```

**We could not verify that any published package provides that overload.** `Package.swift` has no
such dependency, no module named `IntegrationPackage` exists, and the two named-but-missing modules
(`MLXLMHuggingFace`, `MLXEmbeddersHuggingFace`) are the stale spellings from §2.6. What would
resolve this: a released `swift-transformers` (or third-party) version whose module vends
`extension GenericModelFactory { func loadContainer(from: HubClient, configuration:) }` — check its
release notes and public interface.

**SAFE DEFAULT: use style 1 or style 3.** Do not design around an integration package existing.

### 3.4 Style 3 — the MLXHuggingFace macros

Seven freestanding expression macros, ✅ **VERIFIED** by reading their declarations in
`Libraries/MLXHuggingFace/Macros.swift` this session:

```swift illustrative
@freestanding(expression)
public macro hubDownloader(_ hub: Any) -> MLXLMCommon.Downloader

@freestanding(expression)
public macro hubDownloader() -> MLXLMCommon.Downloader

@freestanding(expression)
public macro adaptHuggingFaceTokenizer(_ upstream: Any) -> MLXLMCommon.Tokenizer

@freestanding(expression)
public macro huggingFaceTokenizerLoader() -> MLXLMCommon.TokenizerLoader

@freestanding(expression)
public macro huggingFaceLoadModelContainer(configuration: ModelConfiguration) -> ModelContainer

@freestanding(expression)
public macro huggingFaceLoadModelContainer(
    configuration: ModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void
) -> ModelContainer

@freestanding(expression)
public macro huggingFaceLoadModel(configuration: ModelConfiguration) -> ModelContext

@freestanding(expression)
public macro huggingFaceLoadModel(
    configuration: ModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void
) -> ModelContext
```

Plus, in `Libraries/MLXHuggingFace/FoundationModelsMacros.swift` and gated on the 27 SDK:

```swift illustrative
#huggingFaceLanguageModel(configuration:capabilities:configurationResolver:)  // -> MLXLanguageModel
```

🟡 **RECONSTRUCTED** on that last one's exact parameter list: the research note records it as
`#huggingFaceLanguageModel(configuration:capabilities:configurationResolver:)` annotated
`@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`, and the README's example uses only
`configuration:` and `capabilities:`. Treat `configurationResolver:` as a defaulted parameter whose
spelling is provisional. The two-argument call in the README is ✅ VERIFIED and is what you should
write.

This closes an open question that was live in the earlier research: **`#huggingFaceLoadModelContainer`
has both a bare and a `progressHandler:` form**, and the trailing closure in Apple's sample code
binds to the labelled `progressHandler:` parameter. It is a real second macro overload, not a
default argument.

The dependency set and the imports (✅ VERIFIED, `using.md:132-137` and `README.md:63-100`):

```swift illustrative
// Package.swift
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

The complete quick start, ✅ VERIFIED verbatim from `README.md:86-100`:

```swift prelude:external-module
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

let model = try await #huggingFaceLoadModelContainer(
    configuration: LLMRegistry.gemma3_1B_qat_4bit
)

let session = ChatSession(model)
print(try await session.respond(to: "What are two things to see in San Francisco?"))
print(try await session.respond(to: "How about a great place to eat?"))
```

⚠️ **SILENT FAILURE — the macro expansion needs imports you never wrote.** The expansion references
`Foundation`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXLMCommon`, `HuggingFace` and `Tokenizers`
symbols **at your call site**. If any of those imports is missing, the compiler reports errors
*inside the expanded code* — "cannot find type `HubClient` in scope" pointing at a macro expansion
buffer you did not write — with no hint that the fix is an `import` in your own file. ✅ VERIFIED:
the requirement is documented in `FoundationModelsMacros.swift:17-25`, and the README's example
imports all five modules even though the visible code uses only two of them. **That is not
redundancy — it is required.** Copy the import block verbatim.

The explicit form, if you want to see what the macro is doing (✅ VERIFIED, `using.md:173-177`):

```swift prelude:guide-context
let model = try await LLMModelFactory.shared.loadContainer(
    from: #hubDownloader(),
    using: #huggingFaceTokenizerLoader(),
    configuration: modelConfiguration
)
```

And with a custom cache directory, which is the form you want on iOS so the weights land somewhere
you control (✅ VERIFIED from `mlx-swift-examples`' `Tools/llm-tool/LLMTool.swift:34-43`, transcribed
in the research note — community-adjacent but it is Apple's own sample repo):

```swift prelude:guide-context
var downloader: any Downloader {
    let client =
        if let download {
            HubClient(cache: HubCache(cacheDirectory: download))
        } else {
            HubClient()
        }
    let downloader = #hubDownloader(client)
    return downloader
}
```

### 3.5 Which style, decided

| Your situation | Style |
|---|---|
| Prototype, macOS, weights from Hugging Face | **3** (macros) |
| Shipping iOS app, downloads models at runtime | **1** — you need background URLSession (§6.9) |
| Shipping app, weights bundled or sideloaded | **1**, and you need no `Downloader` at all (§4.5) |
| You already have a tokenizer you trust | **1** |
| You want the smallest build graph | **1** — no swift-syntax |
| Migrating a 2.x app fast, will revisit | **3** — the upgrade doc says so |


---

## 4. Model loading: containers, contexts, downloads, disk

### 4.1 `ModelContext` and `ModelContainer`

`ModelContext` is a plain struct holding the four things you need to run a model. ✅ VERIFIED,
`Libraries/MLXLMCommon/ModelFactory.swift:75-90`:

```swift prelude:guide-context
public struct ModelContext {
    public var configuration: ModelConfiguration
    public var model: any LanguageModel
    public var processor: any UserInputProcessor
    public var tokenizer: Tokenizer
}
```

`ModelContainer` is the thread-safe wrapper around one. ✅ VERIFIED, read from
`Libraries/MLXLMCommon/ModelContainer.swift:31-55` this session:

```swift illustrative
public final class ModelContainer: Sendable {
    private let context: SerialAccessContainer<ModelContext>

    public var configuration: ModelConfiguration { get async }
    public var processor: UserInputProcessor { get async }
    public var tokenizer: Tokenizer { get async }

    public init(context: consuming ModelContext)
}
```

The doc comment above it tells you the intended use in one line (✅ VERIFIED,
`ModelContainer.swift:7-9`): *"Container for models that guarantees single threaded access. Wrap
models used by e.g. the UI in a ModelContainer."*

Access is through `perform`, which has three shapes plus an `update` (✅ VERIFIED, transcribed from
`ModelContainer.swift`):

```swift illustrative
public func perform<R: Sendable>(
    _ action: @Sendable (ModelContext) async throws -> sending R
) async rethrows -> sending R

public func perform<V: Sendable, R: Sendable>(
    values: V, _ action: @Sendable (ModelContext, V) async throws -> R
) async rethrows -> sending R

public func perform<V, R: Sendable>(
    nonSendable values: consuming V, _ action: @Sendable (ModelContext, V) async throws -> R
) async rethrows -> sending R

public func update(_ action: @Sendable (inout ModelContext) -> Void) async
```

And four convenience methods that let you avoid `perform` entirely for the common path
(✅ VERIFIED, `ModelContainer.swift:145-229`):

```swift illustrative
public func prepare(input: consuming sending UserInput) async throws -> sending LMInput
public func generate(input: consuming sending LMInput, parameters: GenerateParameters,
                     wiredMemoryTicket: WiredMemoryTicket? = nil) async throws -> AsyncStream<Generation>
public func decode(tokenIds: [Int]) async -> String
public func encode(_ text: String) async -> [Int]
```

**Prefer the convenience methods.** They exist precisely so you do not have to reason about
`sending` and non-`Sendable` types yourself; the doc comment says *"This method safely prepares input
within the actor's isolation, avoiding the need for closure-based `perform` calls."* (✅ VERIFIED,
`ModelContainer.swift:145-148`).

The most important comment in the whole file is inside `generate` (✅ VERIFIED, verbatim,
`ModelContainer.swift:191-197`):

> Note: this is only visiting the model exclusively for the pre-fill time. Beyond that there is no
> shared mutable state.
>
> This means that there may be concurrent access to the model weights themselves (but they are
> already evaluated).

That is the licence for the pattern in §5.5: **two `ChatSession`s can generate concurrently against
one `ModelContainer`**, because after prefill the only mutable state is each session's own KV cache.

### 4.2 The factory registry, and the error you will hit first

The free functions (`loadModel`, `loadModelContainer`) do not know about `MLXLLM` or `MLXVLM`. They
dispatch through `ModelFactoryRegistry.shared`, which finds factories by **`NSClassFromString`**
(✅ VERIFIED, `ModelFactory.swift:484-497`):

```swift prelude:guide-context
self.trampolines = [
    { (NSClassFromString("MLXVLM.TrampolineModelFactory") as? any ModelFactoryTrampoline.Type)?.modelFactory() },
    { (NSClassFromString("MLXLLM.TrampolineModelFactory") as? any ModelFactoryTrampoline.Type)?.modelFactory() },
]
```

and tries them **in order, keeping only the last error** (✅ VERIFIED, `ModelFactory.swift:413-431`):

```swift prelude:guide-context
private func load<R>(loader: (any ModelFactory) async throws -> sending R) async throws -> sending R {
    let factories = ModelFactoryRegistry.shared.modelFactories()
    var lastError: Error?
    for factory in factories {
        do { return try await loader(factory) } catch { lastError = error }
    }
    if let lastError { throw lastError } else { throw ModelFactoryError.noModelFactoryAvailable }
}
```

⚠️ **SILENT FAILURE — two of them, in six lines.**

**First: `ModelFactoryError.noModelFactoryAvailable` if you did not link `MLXLLM` or `MLXVLM`.** The
registry is populated by module initialisers. If your target links only `MLXLMCommon` — which
compiles fine, because `MLXLMCommon` is self-contained — then `NSClassFromString` returns nil for
both, the factory list is empty, and every load throws before touching the network. `Package.swift`
documents exactly this trap for the package's own test target (✅ VERIFIED, `Package.swift:272-283`,
verbatim):

> MLXLLM is linked here (not by MLXFoundationModels itself) so its module-init registers a factory
> with MLXLMCommon's ModelFactoryRegistry. Without it, loadModelContainer throws
> .noModelFactoryAvailable before ever reaching the downloader, which deadlocks AvailabilityTests'
> in-flight gate.

**Second: VLM is tried before LLM, and intermediate errors are swallowed.** If your LLM fails to
load for a real reason — a corrupt `config.json`, a missing shard — you will often see the *VLM*
factory's error instead, because the loop keeps `lastError` from the final attempt. Diagnose by
calling the specific factory (`LLMModelFactory.shared.loadContainer(...)`) rather than the free
function; you will get the real error.

Use `contains(id:)` before a multi-gigabyte download rather than discovering unsupported-ness
afterwards. The registry doc comment makes the case for you (✅ VERIFIED,
`Registries/ModelTypeRegistry.swift`): *"Lets a caller check support without attempting a (throwing,
allocating) `createModel`, e.g. to decide before a multi-GB download whether a Hub repo's
`model_type` is runnable."*

Note the asymmetry that follows from `AbstractModelRegistry` returning a **fresh
`ModelConfiguration(id:)` for unknown ids**: `configuration(id:)` never fails, so an unknown model id
"just works" up to the point where the *type* registry rejects its `model_type`. ✅ VERIFIED from the
research note's read of `Registries/AbstractModelRegistry.swift`.

### 4.3 Download with progress

The canonical app-level loader is Apple's `LLMBasic` sample. It is short, it is the current house
style, and it solves the double-download problem correctly. ✅ VERIFIED — this is
`Applications/LLMBasic/ChatModel.swift` from `mlx-swift-examples` at HEAD `378f244`, transcribed in
the research note:

```swift prelude:external-module
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import SwiftUI
import Tokenizers

private let modelConfiguration = LLMRegistry.gemma3_1B_qat_4bit

/// Downloads and loads the weights for the model -- we have one of these in the process
@MainActor @Observable public class ModelLoader {

    enum State {
        case idle
        case loading(Task<ModelContainer, Error>)
        case loaded(ModelContainer)
    }

    public var progress = 0.0
    public var isLoaded: Bool {
        switch state {
        case .idle, .loading: false
        case .loaded: true
        }
    }

    private var state = State.idle

    public func model() async throws -> ModelContainer {
        switch self.state {
        case .idle:
            let task = Task {
                // download and report progress
                try await #huggingFaceLoadModelContainer(
                    configuration: modelConfiguration
                ) { value in
                    Task { @MainActor in
                        self.progress = value.fractionCompleted
                    }
                }
            }
            self.state = .loading(task)
            let model = try await task.value

            self.state = .loaded(model)
            return model

        case .loading(let task):
            return try await task.value

        case .loaded(let model):
            return model
        }
    }
}
```

The pattern to internalise: **store the `Task<ModelContainer, Error>` in the `.loading` case.**
Concurrent callers `await task.value` on the *same* task rather than each kicking off a download.
This idiom appears three times across `mlx-swift-examples` (`ChatModel`,
`StableDiffusionExample.ModelFactory`, `LoRAEvaluator`), which is a decent signal that it is the
intended shape.

`value` in the closure is a Foundation `Progress`; `fractionCompleted` is a `Double` in `0...1`.
For a richer UI, `Progress` also gives you `localizedDescription` and
`localizedAdditionalDescription` — `mlx-swift-examples`' `DownloadProgressView` uses both
(✅ VERIFIED via the research note).

For the explicit (non-macro) form, the factory method is the same shape (✅ VERIFIED,
`ModelFactory.swift:148-210`):

```swift illustrative
func loadContainer(
    from downloader: any Downloader,
    using tokenizerLoader: any TokenizerLoader,
    configuration: ModelConfiguration,
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> ContainerType
```

There are also `id:`-based overloads that skip `ModelConfiguration` entirely
(`loadModelContainer(from:using:id:revision:useLatest:progressHandler:)`, with `revision` defaulting
to `"main"` — ✅ VERIFIED, `ModelFactory.swift:279-411`).

🔴 **GAP — what `useLatest:` actually does.** It appears in every loading signature, defaults to
`false`, and is passed straight through to `Downloader.download(id:revision:matching:useLatest:...)`.
We could not find a doc comment or implementation that defines its semantics; the plausible reading
is "re-check the remote for a newer revision instead of trusting the local snapshot," but that is a
guess and this guide does not print guesses. **What would resolve it:** the doc comment on the
`Downloader` protocol in a released DocC build, or `HubClient.downloadSnapshot`'s handling in
`swift-huggingface`. **SAFE DEFAULT: leave it at `false`.** That is what every Apple call site does.

### 4.4 Where the weights land

For the Hugging Face path, the answer is the standard HF cache layout. ✅ VERIFIED from the shipped
agent skill, `skills/mlx-swift-lm/references/model-container.md:245-258`:

```swift prelude:guide-context
let resolved = try await resolve(
    configuration: configuration,
    from: HubClient.default,
    progressHandler: { _ in }
)
let modelDir = resolved.modelDirectory
// ~/.cache/huggingface/hub/models--mlx-community--Model-Name/...
```

The `resolve` step is the single place downloads happen, and it does four things
(✅ VERIFIED, `ModelFactory.swift:228-263`):

- `.id(id, revision)` → `downloader.download(id:revision:matching: modelDownloadPatterns, useLatest:progressHandler:)`
- `.directory(url)` → used as-is, **no download**
- `tokenizerSource == .id(...)` → a second download with `tokenizerDownloadPatterns` and a **no-op**
  progress handler
- `tokenizerSource == nil` → the tokenizer directory *is* the model directory

The result is a `ResolvedModelConfiguration` (✅ VERIFIED, `Downloader.swift:69-101`):

```swift prelude:guide-context
public struct ResolvedModelConfiguration: Sendable {
    public var modelDirectory: URL
    public var tokenizerDirectory: URL
    public var name: String
    public var defaultPrompt: String
    public var extraEOSTokens: Set<String>
    public var stopStrings: Set<String>
    public var eosTokenIds: Set<Int>
    public var toolCallFormat: ToolCallFormat?
    public var reasoningConfig: ReasoningConfig?
}
```

⚠️ **On iOS, `~/.cache` is the wrong place.** The default cache lives under the app's `Library/Caches`
if you use `HubClient()` bare, and **`Library/Caches` is purgeable — iOS can delete it under storage
pressure, without telling you.** A multi-gigabyte model vanishing between launches is a support
ticket you will not enjoy. Apple's own `MLXChatExample` splits by platform (✅ VERIFIED from the
research note's read of `Support/HubApi+default.swift`, though that file is now vestigial in that
sample):

```swift illustrative
#if os(macOS)
    // Downloads directory
#else
    // URL.cachesDirectory.appending(path: "huggingface")
#endif
```

A shipping third-party iOS app makes the opposite, and better, choice — **community-measured,
from a deep read of the [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md), which stores models under `Documents`**:

```swift illustrative
static func baseDir(for format: ModelFormat, modelID: String) -> URL {
    var dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalLLMModels", isDirectory: true)
    if let owner = splitModelID(modelID).owner, !owner.isEmpty {
        dir.appendPathComponent(owner, isDirectory: true)
    }
    dir.appendPathComponent(sanitizedRepoComponent(for: format, repo: parts.repo), isDirectory: true)
    return dir
}
```

i.e. `Documents/LocalLLMModels/<owner>/<repo>/…`, combined with `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` in `Info.plist` so users can see and delete models in Files.app.
Attribution: community source, read from that repo's source this session; not an Apple
recommendation.

Two hard-won details from the same source, both worth stealing:

- **`rehomeIfMissing()`** — the app sandbox container path changes across installs, so absolute URLs
  stored in a database go stale. The app re-resolves paths on launch instead of assuming.
- Validation helpers before trusting a downloaded file: `isGitLFSPointer(at:)`,
  `isValidSafetensorsFile(at:)`, `sha256Matches(fileURL:expected:)`. **`isGitLFSPointer` is the one
  people forget** — a misconfigured mirror serves you a 133-byte text file where a 4 GB safetensors
  should be, and `loadArraysAndMetadata` fails much later with an opaque error.

### 4.5 Shipping or sideloading your own weights

If your weights are already on disk you do not need a `Downloader` at all. There are directory-based
overloads at every level. ✅ VERIFIED, `ModelFactory.swift:148-210` and `:279-411`:

```swift illustrative
func load(from directory: URL, using tokenizerLoader: any TokenizerLoader) async throws -> sending ContextType
func loadContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader) async throws -> ContainerType

// free functions
loadModel(from directory: URL, using tokenizerLoader: any TokenizerLoader)
loadModelContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader)
```

and `ModelConfiguration` has a directory initialiser (✅ VERIFIED,
`Libraries/MLXLMCommon/ModelConfiguration.swift:16-184`):

```swift illustrative
public init(directory: URL, tokenizerSource: TokenizerSource? = nil,
            defaultPrompt: String = "", extraEOSTokens: Set<String> = [],
            stopStrings: Set<String>? = nil, eosTokenIds: Set<Int> = [],
            toolCallFormat: ToolCallFormat? = nil, reasoningConfig: ReasoningConfig? = nil)
```

Here is a complete bundle-loading path. **The tokenizer loader is still yours to supply** — that is
the one thing a directory does not free you from:

```swift prelude:external-module
import Foundation
import MLXLLM
import MLXLMCommon

/// Loads a model from a directory inside the app bundle. No network, no Downloader.
enum BundledModel {

    enum LoadError: Error {
        case resourceMissing(String)
        case notADirectory(URL)
        case missingConfig(URL)
    }

    /// - Parameter name: the folder name inside the bundle, e.g. "Qwen3-1.7B-4bit"
    static func load(
        named name: String,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContainer {

        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
            throw LoadError.resourceMissing(name)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LoadError.notADirectory(url)
        }

        // Fail early and legibly rather than deep inside the factory.
        let config = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw LoadError.missingConfig(url)
        }

        return try await LLMModelFactory.shared.loadContainer(
            from: url,
            using: tokenizerLoader
        )
    }
}
```

Three practical notes on bundling:

1. **Add the model folder to Xcode as a *folder reference* (blue), not a group (yellow).** A group
   flattens the hierarchy into the bundle root and `config.json` will not be where the loader looks.
   This is a general Xcode fact, not an MLX one, but it is the failure everyone hits once.
2. **The App Store binary limit still applies.** A 4-bit 4B model is roughly 2.3 GB (see the
   measured numbers in §6.4) — that is a very large app. On-demand resources or a first-run download
   are usually the right call; bundling is for small models and for enterprise/MDM distribution.
3. **`config.json` is mandatory** and its absence is the most common sideload failure. The load
   pipeline reads it first and throws `ModelFactoryError.configurationFileError` (✅ VERIFIED,
   `Libraries/MLXLLM/LLMModelFactory.swift:569-669`, step 1). A community app makes the same check
   for the same reason and throws its own `MLXBridgeError.invalidModel` — community-measured, from
   the Noema read.

### 4.6 What load actually does, in order

Worth knowing because two of the steps have surprising semantics. ✅ VERIFIED,
`Libraries/MLXLLM/LLMModelFactory.swift:569-669`:

1. Read `config.json` from `configuration.modelDirectory`; failure ⇒
   `ModelFactoryError.configurationFileError`.
2. `JSONDecoder.json5().decode(BaseConfiguration.self, …)`; a `DecodingError` ⇒
   `.configurationDecodingError`. **Every config decode in this package allows JSON5** — trailing
   commas and comments in a hand-edited `config.json` will not break you.
3. `typeRegistry.createModel(configuration: configData, modelType: baseConfig.modelType)`.
4. EOS ids: start from `baseConfig.effectiveEOSTokenIds`; if `generation_config.json` has
   `eos_token_id`, **replace** the set — the source comment says
   `// Override per Python mlx-lm behavior`.
5. `mutableConfiguration.stopStrings.formUnion(generationConfig?.stopStrings ?? [])`.
6. `toolCallFormat` inferred from `model_type` + config data if not preset.
7. `reasoningConfig` inferred likewise (LLM factory only — the **VLM factory does not do this**).
8. Tokenizer load runs **in parallel** with weight loading via `async let`.
9. `messageGenerator` from `LLMModel.messageGenerator(tokenizer:)`.
10. Build a directory-flavoured `ModelConfiguration` and an `LLMUserInputProcessor`.

⚠️ Step 4 is a real trap. `generation_config.json`'s `eos_token_id` **replaces rather than unions**
the set from `config.json`. If you hand-edit a checkpoint to add an extra stop token in
`config.json` and the repo also ships a `generation_config.json`, your edit is discarded silently and
the model runs past where you wanted it to stop. Put extra stop tokens in
`ModelConfiguration.extraEOSTokens` instead — that set is unioned, not replaced.

And step 8's parallelism has a consequence for your progress UI: **you cannot report "loading
tokenizer" and "loading weights" as sequential phases**, because they are not.

Weight loading itself honours a safetensors index when present (✅ VERIFIED,
`Libraries/MLXLMCommon/Load.swift:15-33`, added in commit `f5f18ed`, *"fix: Honor safetensors index
when loading weights (#408)"*): if `model.safetensors.index.json` exists, the deduplicated, sorted
`weight_map` values are used; otherwise `*.safetensors` is enumerated recursively. If you are
building your own checkpoints, ship the index — recursive enumeration will happily pick up a stray
`.safetensors` in a subfolder.


---

## 5. Concurrency: what runs where, and what is Sendable

### 5.1 The shipped skill, and how far to trust it

`mlx-swift-lm` ships an **agent skill** in `skills/mlx-swift-lm/` — a `SKILL.md` plus twelve
reference files. ✅ VERIFIED, read this session. Three of them are essentially the outline of this
guide: `concurrency.md` (387 lines), `model-container.md` (321), `wired-memory.md` (120). Installing
it is a symlink (✅ VERIFIED, `skills/README.md`):

```sh
# Claude Code
mkdir -p ~/.claude/skills && ln -s "$(pwd)/skills/mlx-swift-lm" ~/.claude/skills/mlx-swift-lm
# Codex
mkdir -p ~/.codex/skills && ln -s "$(pwd)/skills/mlx-swift-lm" ~/.codex/skills/mlx-swift-lm
# Droid
mkdir -p ~/.agents/skills && ln -s "$(pwd)/skills/mlx-swift-lm" ~/.agents/skills/mlx-swift-lm
```

Per-project variants use `.claude/skills`, `.codex/skills`, `.agents/skills`. `cp -R` works instead
of `ln -s`. *"If your tool caches skills, restart it after installing."*

⚠️ **The skill's *loading* code is stale relative to the 3.x API in the same repo.** ✅ VERIFIED by
direct read: `skills/mlx-swift-lm/references/concurrency.md:131-135` contains

```swift prelude:guide-context
let container = try await loadModelContainer(
    from: HubClient.default,
    using: TokenizersLoader(),  // TokenizersLoader() from MLXLMTokenizers (swift-tokenizers-mlx)
    id: "mlx-community/Qwen3-4B-4bit"
)
```

**`MLXLMTokenizers`, `swift-tokenizers-mlx` and `TokenizersLoader()` do not exist** — not in
`Package.swift`, not in `README.md`, not in `using.md`. The same stale names appear in
`Libraries/MLXLMCommon/README.md`, `Libraries/MLXLLM/README.md`, `Libraries/MLXVLM/README.md` and
`Libraries/MLXEmbedders/README.md`. There is also a name mismatch in the skill's own front matter:
the directory is `mlx-swift-lm` but `name:` is `swift-mlx-lm`.

**Use the skill for its *concurrency semantics*, which are accurate and match the source, and ignore
its loading snippets.** Substitute `#hubDownloader()` / `#huggingFaceTokenizerLoader()` (§3.4) or
your own conformances (§3.2). If you install the skill for a coding agent, tell the agent this
explicitly, or it will confidently write code that does not compile — which is exactly the failure
mode this guide series exists to prevent.

### 5.2 `SerialAccessContainer` — and why it is not an actor

This is the most interesting design decision in the package, and the skill explains it better than
anything else in the repo. ✅ VERIFIED, `skills/mlx-swift-lm/references/concurrency.md:31-53`,
verbatim:

> ### Why Not Actor?
>
> Actors release isolation at `await` points. `SerialAccessContainer` maintains the lock:
>
> ```swift
> // Actor example - isolation released at await
> actor MyActor {
>     var state: Int = 0
>     func process() async {
>         state = 1
>         await someAsyncWork()  // Another caller can modify state here!
>         state = 2
>     }
> }
>
> // SerialAccessContainer - exclusive for entire async operation
> let container = SerialAccessContainer(0)
> await container.update { state in
>     state = 1
>     await someAsyncWork()  // Exclusive access maintained
>     state = 2
> }
> ```

The source says the same thing in one sentence (✅ VERIFIED,
`Libraries/MLXLMCommon/Utilities/SerialAccessContainer.swift:39-43`, verbatim):

> Unlike an `actor`, this will guarantee exclusive access for the duration of the async call. This
> is important for things like `ModelContainer` that have to perform async work but also need to
> prevent other callers for using _any_ of the internal state.

This is *the* Swift-concurrency lesson of the whole MLX Swift stack: **actor reentrancy is wrong for
model access.** A `ModelContext` holds weights and a tokenizer; a generation call awaits repeatedly
(prefill chunks, `asyncEval`, stream synchronisation). With a plain actor, a second caller can slip
in at any of those suspension points and start its own prefill on the same weights with a different
KV cache. `SerialAccessContainer` is an async mutex — a `private actor AsyncMutex` holding
`isLocked` plus an array of `CheckedContinuation<Void, Never>` waiters — wrapped around the value:

```swift illustrative
package final class SerialAccessContainer<T>: @unchecked Sendable {
    public init(_ value: consuming T)
    public func read<R>(_ body: @Sendable (T) async throws -> sending R) async rethrows -> sending R
    public func update<R>(_ body: @Sendable (inout T) async throws -> sending R) async rethrows -> sending R
}
```

✅ VERIFIED, `SerialAccessContainer.swift`.

⚠️ **`SerialAccessContainer` and `SendableBox` are `package`-scoped, not `public`.** ✅ VERIFIED from
the same file. You cannot use them in your own code. If you want the pattern, you must reimplement
it — which is a reasonable thing to do, and the skill's excerpt above is enough of a spec to do it
from. What you *do* get publicly is `ModelContainer`, which is built on it.

Note the design consequence you inherit anyway: **a long generation holds the container's lock for
its prefill**, so a second `perform` on the same container waits. That is correct, and it is why
§5.5's concurrent-sessions pattern deliberately pulls the model *out* of the container.

### 5.3 `MLXArray` is not `Sendable`

This is the constraint that shapes every signature in the package. ✅ VERIFIED — stated in
`skills/.../concurrency.md:270-305`, in `ModelContainer.perform`'s doc comment (*"Callers must eval
any `MLXArray` before returning as `MLXArray` is not `Sendable`"*, ✅ VERIFIED
`ModelContainer.swift:57-58`), and corroborated independently by the `mlx-swift-examples` research
note.

Three strategies, from the skill (✅ VERIFIED, `concurrency.md:274-305`):

**1. Eval before returning, and return a primitive.**

```swift prelude:guide-context
await container.perform { context in
    let result = context.model(input)
    eval(result)                    // Evaluate before crossing boundary
    return result.item(Float.self)  // Return primitive
}
```

**2. Transfer with a box.**

```swift prelude:guide-context
let box = SendableBox(array)
Task {
    let array = box.consume()
    // Use array in this task only
}
```

**3. Keep arrays inside one isolation region.**

```swift prelude:guide-context
await container.perform { context in
    let a = model(input1)
    let b = model(input2)
    let combined = a + b
    eval(combined)
    return combined.item()
}
```

The *reason* strategy 1 needs the `eval` is MLX's laziness. An unevaluated `MLXArray` is a node in a
computation graph, not data; hand it across an isolation boundary and you have handed across a
promise whose evaluation may then race. The `mlx-swift-examples` note records the same rule from the
other direction — *"every `perform`/`performTwoStage` doc comment says callers must `eval()` before
returning arrays across the isolation boundary."*

There is a related, subtler rule that comes from the wider MLX stack and applies here too:
**MLX arrays are thread-affine — build them on the thread that runs the model.** Community-measured,
from the cross-repo issue-mining pass (gotcha 22 in that note's checklist). In practice this is
automatic if you obey strategy 3.

⚠️ **`SendableBox.consume()` `fatalError`s on a second call** — ✅ VERIFIED,
`SerialAccessContainer.swift`, message `"value already consumed"`, and restated in the skill
(`concurrency.md:104-110`). If you reimplement the pattern, reproduce the trap deliberately: a
silent second `consume` returning garbage would be far worse than a crash.

### 5.4 `ChatSession` is not thread-safe. `ModelContainer` is.

✅ VERIFIED from the source doc comment on `ChatSession` — *"Each session should be used from a single
task/thread at a time"* — and restated in the skill (`concurrency.md:150-170`):

```swift illustrative
// WRONG: Multiple tasks using same session
let session = ChatSession(container)
Task { await session.respond(to: "A") }  // Race condition!
Task { await session.respond(to: "B") }

// CORRECT: Single task per session
let session = ChatSession(container)
let r1 = await session.respond(to: "A")
let r2 = await session.respond(to: "B")

// Or: Separate sessions per task
Task {
    let session = ChatSession(container)  // Own session
    await session.respond(to: "...")
}
```

`ChatSession` is a `public final class` with mutable public properties (`instructions`, `processing`,
`generateParameters`, `additionalContext`, `tools`, `toolDispatch`) — ✅ VERIFIED,
`Libraries/MLXLMCommon/ChatSession.swift`. It is not an actor and it is not `Sendable`. Treat it as
you would a `UIView`: one owner, one task.

The rule to carry: **one `ModelContainer` per model in the process; one `ChatSession` per
conversation; never share a session across tasks.**

### 5.5 Two conversations, one model

Because `ChatSession` internally lifts the model *out* of the container via `SendableBox` and locks
only its own KV cache, **multiple sessions can generate in parallel against the same weights**.
✅ VERIFIED from `ChatSession.swift:574-836`'s `streamMap` implementation and its comment, quoted in
the research note: *"the KVCache cannot be shared and that is the lock that is held here."*

```swift prelude:external-module
import MLXLMCommon

/// Two independent conversations sharing one set of weights.
actor ConversationRegistry {
    private let container: ModelContainer
    private var sessions: [UUID: ChatSession] = [:]

    init(container: ModelContainer) { self.container = container }

    /// Each conversation gets its own session — and therefore its own KV cache.
    func session(for id: UUID, instructions: String?) -> ChatSession {
        if let existing = sessions[id] { return existing }
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(temperature: 0))
        sessions[id] = session
        return session
    }

    func discard(_ id: UUID) async {
        // Free the KV cache promptly; weights stay resident in the container.
        await sessions[id]?.clear()
        sessions[id] = nil
    }
}
```

The memory cost of this is **one KV cache per live session**, which is not free — see §6.6 for the
sizing formula. `ChatSession.clear()` resets the cache to `.empty` while keeping `instructions`
(✅ VERIFIED, `ChatSession.swift`), so it is the right call when a conversation goes idle.

`ChatSession` also exposes `synchronize()`, documented as waiting for exclusive access to the
KV cache (✅ VERIFIED). Use it before tearing a session down if you need to know generation has
actually stopped.

### 5.6 Cancellation — and the iOS crash it prevents

This is the single best piece of evidence in the repo that the authors have shipped on iOS. Two
cooperative-cancellation checks exist, both with comments explaining a real crash.

**In the prefill loop** (✅ VERIFIED, read this session from `Libraries/MLXLLM/LLMModel.swift`,
verbatim):

```swift compile:27
// Cooperative cancellation between prefill windows. On iOS, GPU work
// submitted after the app moves to the background is rejected by the
// system ("Insufficient Permission"), and the resulting command-buffer
// error is thrown from a Metal completion handler where it cannot be
// caught, aborting the process. Without this check a long prompt's
// prefill cannot be interrupted, so apps cannot stop GPU submissions
// in time when entering the background. See ml-explore/mlx-swift-examples#230.
try Task.checkCancellation()
```

**In the generation loop** (✅ VERIFIED, read this session from
`Libraries/MLXLMCommon/Evaluate.swift:1899-1906`, verbatim):

```swift illustrative
// pipeline the next GPU evaluation, so checking after it (the previous
// `while let token = iterator.next()` form) allowed one extra asyncEval to be
// submitted post-cancellation, which faults if the app has backgrounded
// (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted). The
// post-loop block below assigns `.cancelled`; Stream().synchronize() still
// settles any in-flight evaluation at the end of the task body.
tokenLoop: while !Task.isCancelled {
    guard let token = autoreleasepool(invoking: { iterator.next() }) else { break }
```

⚠️ **SILENT FAILURE — well, not silent: it kills your process.** Read those two comments together
and the rule is stark. **If your app backgrounds while MLX has GPU work in flight, the Metal
command-buffer error arrives on a completion handler where Swift cannot catch it, and the process is
aborted.** Not an exception, not a returned error — a crash, attributed to your app, in a stack
trace that names Metal rather than MLX. The cancellation check *before* `iterator.next()` (rather
than after) exists specifically because `next()` calls `asyncEval` to pipeline the next step, so
checking afterwards let exactly one extra command buffer escape.

What this means for your app, concretely:

1. **Cancel generation on `scenePhase` change to `.background`.** Do not rely on the system.
2. **`await` the generation task after cancelling**, so `Stream().synchronize()` runs before you are
   suspended.
3. Do not start generation from a background-launched context.

```swift prelude:guide-context
import SwiftUI

struct ChatScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel

    var body: some View {
        ChatBody(model: model)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    // Stop submitting GPU work before the process is suspended.
                    Task { await model.cancelAndSettle() }
                }
            }
    }
}

@MainActor @Observable
final class ChatModel {
    private var task: Task<Void, Error>?

    /// Cancel, then wait for the generation task to actually finish.
    /// Returning before it settles is what leaves a command buffer in flight.
    func cancelAndSettle() async {
        guard let task else { return }
        task.cancel()
        _ = try? await task.value
        self.task = nil
    }
}
```

There is corroborating history: issue **#382** (CLOSED), *"Cancelling generation can still submit one
more GPU evaluation (iOS/iPadOS crash)"*; PR **#423** added the cooperative check to the prefill
loop; PR **#413** cancels the generation task when the consumer goes away. Community-sourced, from
the issue-mining note — but the fixes are in the source you are compiling.

### 5.7 Early `break` leaves work in flight

Related, and much less dramatic, but it will corrupt a conversation. ✅ VERIFIED — the doc comment on
`generate` says it outright (`Evaluate.swift:1425-1429`, verbatim):

> if the stream is terminated early (e.g. break from the loop) computation will continue using the
> model, parameters, KVCache, etc. for some time (typically a few ms). This is typically OK for
> one-shot calls, but for 'chat session' type calls consider using `generateTask(...)` so that the
> end of the generation task can be observed.

The `…Task` variants return `(AsyncStream<Generation>, Task<Void, Never>)` so you can await the
second element (✅ VERIFIED, `Evaluate.swift`):

```swift illustrative
public func generateTask<TOKEN: TokenIteratorProtocol>(
    promptTokenCount: Int, modelConfiguration: ModelConfiguration, tokenizer: Tokenizer,
    iterator: consuming TOKEN, wiredMemoryTicket: WiredMemoryTicket? = nil,
    tools: [[String: any Sendable]]? = nil) -> (AsyncStream<Generation>, Task<Void, Never>)

public func generateTokensTask(input:cache:parameters:context:includeStopToken:wiredMemoryTicket:)
    throws -> (AsyncStream<TokenGeneration>, Task<Void, Never>)
```

The skill's phrasing of the pattern (✅ VERIFIED, `concurrency.md:208-228`):

```swift prelude:guide-context
let (stream, task) = generateTask(
    promptTokenCount: count,
    modelConfiguration: config,
    tokenizer: tokenizer,
    iterator: iterator
)

for await item in stream {
    if shouldStop {
        break
    }
}

// Wait for generation to fully stop
await task.value
```

The stream also self-cancels on consumer teardown — `continuation.onTermination = { if case
.cancelled = $0 { task.cancel() } }` (✅ VERIFIED, `Evaluate.swift:1149`) — so `break` does stop the
loop; the point is that it does not stop it *synchronously*, and the KV cache is still being written
for a few milliseconds afterwards.

### 5.8 Throwing versus non-throwing streams

A small API asymmetry that costs everyone one compile error. ✅ VERIFIED,
`concurrency.md:193-206`:

- **`MLXLMCommon.generate(...)`** — *creation* can throw; **iteration cannot**. It returns
  `AsyncStream<Generation>`. So: `let stream = try generate(...)`, then `for await`.
- **`ChatSession.streamResponse(...)`** — returns `AsyncThrowingStream<String, Error>`. So:
  `for try await chunk in session.streamResponse(to: prompt)`.

```swift illustrative
// Non-throwing iteration, throwing construction
let stream = try generate(input: input, parameters: params, context: context)
for await event in stream { … }

// Throwing iteration
for try await chunk in session.streamResponse(to: prompt) { … }
```

The event type from the low-level API is a three-case enum (✅ VERIFIED, `Evaluate.swift:1112-1118`
and corroborated by Apple's `MLXChatExample`):

```swift prelude:guide-context
public enum Generation: Sendable {
    case chunk(String)
    case info(GenerateCompletionInfo)
    case toolCall(ToolCall)
    public var chunk: String?; public var info: GenerateCompletionInfo?; public var toolCall: ToolCall?
}
```

⚠️ Apple's own `llm-tool` ends its consumption loop with
`fatalError("exited loop without seeing .info")` — i.e. **the stream is expected always to terminate
with a `.info` event**. ✅ VERIFIED via the `mlx-swift-examples` research note (§15, gotcha 22). Do
*not* copy the `fatalError`, but do rely on `.info` arriving: it carries `stopReason`,
`promptTokenCount`, `tokensPerSecond` and the timings you need for §8's metrics UI.

### 5.9 Where MLX work actually runs

Putting the pieces together, the isolation map for a typical app:

| Work | Where it runs | Why |
|---|---|---|
| `ModelLoader` state machine | `@MainActor` | it drives SwiftUI |
| Download `progressHandler` | any; hop to `@MainActor` inside | the macro's expansion already does |
| `loadContainer` | a detached `Task` | multi-second, must not block UI |
| `container.perform { … }` | container's serial region | exclusive by construction |
| Prefill | inside `perform` / `TokenIterator.init` | expensive; holds the lock |
| Token loop | the generation `Task` | released the container lock after prefill |
| Consuming `AsyncStream` | `@MainActor` is fine | strings only, `Sendable` |
| `MLXArray` manipulation | one isolation region, `eval` at the edge | not `Sendable`, thread-affine |

The one line to remember: **`TokenIterator.init` performs the prefill.** ✅ VERIFIED,
`Evaluate.swift:1020-1021` — `self.promptPrefillTime = try measure { try prepare(...) }`. Constructing
the iterator is the expensive, throwing call; `next()` is comparatively cheap. If your profiler shows
a multi-second stall inside what looks like an initialiser, that is why, and it is not a bug.


---

## 6. Memory: the section that decides whether you ship

On macOS, memory is a performance problem. On iOS it is an existence problem: exceed your process
limit and the kernel kills you, with no exception to catch and no `deinit` to run. This section is
ordered by what you have to do first.

### 6.1 The entitlement, before anything else

**Every** LLM/VLM/diffusion sample app in `mlx-swift-examples` enables
`com.apple.developer.kernel.increased-memory-limit`. ✅ VERIFIED — the research note transcribes
`MLXChatExample.entitlements` verbatim and tabulates all six apps:

```xml
<dict>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.downloads.read-write</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
```

| App | increased-memory-limit | app-sandbox | network.client | files.user-selected.read-only | files.downloads.read-write |
|---|---|---|---|---|---|
| LLMBasic | ✅ | — | — | — | — |
| LLMEval | ✅ | ✅ | ✅ | ✅ | — |
| LoRATrainingExample | ✅ | ✅ | ✅ | ✅ | — |
| MLXChatExample | ✅ | ✅ | ✅ | ✅ | ✅ |
| MNISTTrainer | — | ✅ | ✅ | ✅ | — |
| StableDiffusionExample | ✅ | ✅ | ✅ | ✅ | — |

Apple's own README for `LLMBasic` states the reason (✅ VERIFIED, `Applications/LLMBasic/README.md:19-23`,
verbatim):

> - this downloads models from hugging face so LLMBasic -> Signing & Capabilities has the "Outgoing
>   Connections (Client)" set in the App Sandbox
> - LLM models are large so this uses the Increased Memory Limit entitlement on iOS to allow ...
>   increased memory limits for devices that have more memory
> - `Memory.cacheLimit = 20 * 1024 * 1024` is used to limit the buffer cache size

Note MNISTTrainer is the one app *without* it — because MNIST is tiny. That is the tell: the
entitlement is not boilerplate, it is a statement that your app intends to hold gigabytes.

A shipping third-party app carries it too, alongside two others that matter for this domain —
community-measured, read from the [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
`Noema.entitlements`:

```xml
<key>com.apple.developer.background-tasks.continued-processing.gpu</key><true/>
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
<key>com.apple.developer.private-cloud-compute</key><true/>
```

with the note that `kernel.increased-memory-limit` is **"mandatory for shipping big local LLMs on
iOS"**, `background-tasks.continued-processing.gpu` is the iOS 26 `BGContinuedProcessingTask` GPU
class, and `private-cloud-compute` is the iOS 27 PCC entitlement. Attribute as community.

### 6.2 ⚠️ The GPU cache API changed name — and both spellings are in the wild

This is the correction most likely to waste your afternoon.

**The current API is a `Memory` namespace in the `MLX` module.** ✅ VERIFIED from three independent
places read this session:

- `Libraries/MLXLMCommon/Evaluate.swift:786` — `MLX.Memory.clearCache()`
- `Libraries/MLXFoundationModels/MLXLanguageModel.swift:403` — `MLX.Memory.cacheLimit = 256 * 1024 * 1024`
- `Libraries/MLXLMCommon/Documentation.docc/wired-memory.md:29,56` — `Memory.snapshot()`

and the `mlx-swift-examples` research note is emphatic about it:

> **BREAKING vs. older tutorials.** The old idiom `MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)` **does
> not appear anywhere in this repo**. It has been replaced by a `Memory` enum/namespace in the `MLX`
> module.

Verified surface, from that note's read of `mlx-swift-examples` at HEAD `378f244`:

| Symbol | Type | Seen in |
|---|---|---|
| `Memory.cacheLimit` | settable `Int` (bytes) | `LLMBasicApp.swift:12`, `MLXService.swift:56`, `LLMEvaluator.swift:105`, and every CLI's `MemoryArguments` |
| `Memory.memoryLimit` | settable **and readable** `Int` (bytes) | `StableDiffusionExample/ContentView.swift:141` reads it |
| `Memory.snapshot()` | `-> Memory.Snapshot` | `DeviceStat.swift`, all CLI `MemoryArguments` |
| `Memory.Snapshot.activeMemory` / `.cacheMemory` / `.peakMemory` | `Int` | `LLMEval/Views/ContentView.swift:58-60` |
| `Memory.Snapshot.delta(_:)` | `-> Memory.Snapshot` | `DeviceStat.swift:26` |
| `Memory.clearCache()` | `()` | `Evaluate.swift:786`, `BenchmarkHelpers.swift` (×6) |

**But `GPU.set(cacheLimit:)` has not vanished from the ecosystem.** A shipping third-party app,
pinned to an older `mlx-swift-lm` revision (`702e5a0`) and to `mlx-swift` **branch `main`**, calls
`MLX.GPU.set(cacheLimit:)` — community-measured, read from the
[frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md), `MLXBridge.swift`, this
session. And `mlx-swift-lm` still calls **`GPU.maxRecommendedWorkingSetBytes()`** in three places
(✅ VERIFIED: `WiredMemoryPolicies.swift:8`, `SpeculativeDecoding.swift:7` and `:167`), so the `GPU`
namespace is alive; it is the *cache-limit setter* that moved.

🔴 **GAP: whether `GPU.set(cacheLimit:)` still exists as a deprecated alias in mlx-swift 0.31.x.**
The `mlx-swift` repository was not available to read this session, and both spellings appear in code
that compiles against 2026 toolchains. **What would resolve it:** `Source/MLX/GPU.swift` and
`Source/MLX/Memory.swift` in `ml-explore/mlx-swift` at the tag your project resolves.
**SAFE DEFAULT: write `Memory.cacheLimit`.** It is what Apple's current samples and
`mlx-swift-lm`'s own source use. If it does not compile, your resolved `mlx-swift` is older than
0.31.4 and you should upgrade rather than fall back.

### 6.3 What the two limits mean, and what to set them to

- **`Memory.cacheLimit`** — the ceiling on MLX's **Metal buffer-reuse pool**. This is *recycled*
  memory, not live data. Setting it low means MLX frees buffers back to Metal aggressively; setting
  it high means fewer allocations and less allocator thrash, at the cost of resident bytes that are
  not doing useful work.
- **`Memory.memoryLimit`** — a ceiling on MLX's total allocation. It is **readable before you set
  it**, and MLX seeds it from the device's recommended working-set size, which makes it a device-size
  probe.

The canonical app idiom, ✅ VERIFIED — the whole of `Applications/LLMBasic/LLMBasicApp.swift`:

```swift prelude:external-module
// Copyright © 2025 Apple Inc.

import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI

@main
struct LLMBasicApp: App {

    init() {
        Memory.cacheLimit = 20 * 1024 * 1024
    }

    @State var loader = ModelLoader()

    var body: some Scene {
        WindowGroup {
            ContentView(loader: loader)
        }
    }
}
```

What Apple actually ships, per app (✅ VERIFIED from the research note's survey):

| App | `cacheLimit` | `memoryLimit` |
|---|---|---|
| LLMBasic | 20 MB | — |
| LLMEval | 20 MB | — |
| MLXChatExample | 20 MB | — |
| LoRATrainingExample | 32 MB | — |
| StableDiffusionExample, low-memory device | **1 MB** | **3 GB** |
| StableDiffusionExample, normal | **256 MB** | — |
| `llm-tool` / `image-tool` / `embedder-tool` | `--cache-size` MB (image-tool default **1024**) | `--memory-size` MB |

And `mlx-swift-lm`'s own FoundationModels adapter sets **256 MB**, once per process, with a
justification worth reading in full (✅ VERIFIED, read this session from
`Libraries/MLXFoundationModels/MLXLanguageModel.swift:396-404`, verbatim):

```swift illustrative
/// Sets the process-global MLX buffer-reuse pool limit a single time. A
/// `static let` initializer runs lazily and exactly once (thread-safe), so
/// repeated model loads don't re-stomp a consumer's own `Memory.cacheLimit`.
///
/// Higher = less allocator thrash at the cost of slightly higher resident GPU
/// memory. 256MB comfortably holds activations and KV cache for a 3B model
/// without forcing pool evictions mid-forward-pass.
private static let configureGPUCacheOnce: Void = {
    MLX.Memory.cacheLimit = 256 * 1024 * 1024
}()
```

⚠️ **`Memory.cacheLimit` is a single process-wide value, and libraries set it behind your back.**
The `static let`-runs-once trick above exists specifically so the adapter does not clobber a value
you set in your `App.init()` — but note the ordering: whichever runs *last* wins, and the adapter's
runs on first model load, i.e. **after** your `init()`. Read that comment as: *the adapter will win
unless you set it again after your first load.* If you care about the value, set it after load and
assert it.

**So which number?** The 20 MB figure in Apple's samples is a conservative iOS default and it is not
right for every case. Two pieces of evidence complicate it:

1. **Apple's own StableDiffusion sample uses 256 MB on a normal machine** and 1 MB only when
   conserving.
2. A shipping app abandoned the flat 20 MB deliberately. Community-measured, from the
   [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
   `MLXBridge.swift`, verbatim comment plus code:

```swift illustrative
/// Max bytes MLX keeps in its Metal buffer-reuse cache. The old flat 20 MB starved large
/// models on Mac — every op had to re-allocate/free big Metal buffers instead of reusing
/// them, throttling throughput badly. Scale with available RAM, generous on Mac (ample
/// unified memory), modest on the memory-constrained (jetsam-prone) mobile platforms.
static var gpuCacheLimitBytes: Int {
    let ram = Int(ProcessInfo.processInfo.physicalMemory)
    #if os(macOS)
    return min(1024*1024*1024, max(256*1024*1024, ram / 16))
    #else
    return min(128*1024*1024, max(32*1024*1024,  ram / 32))
    #endif
}
static func retainGPUCache()  { count += 1; MLX.GPU.set(cacheLimit: gpuCacheLimitBytes) }
static func releaseGPUCache() { count -= 1; if count == 0 { MLX.GPU.set(cacheLimit: 0) } else { reassert() } }
```

with this rationale, verbatim:

> The Metal buffer-cache limit is a single PROCESS-WIDE value, but on macOS two MLX models can be
> resident at once (the chat model + Autopilot's local escalation model). A naive `set(0)` in one
> client's unload() would starve the other.

That refcount is the design lesson, independent of which API spelling you use: **if more than one
component in your process can load an MLX model, the cache limit needs an owner.** Translate that
snippet to `Memory.cacheLimit` for current `mlx-swift`.

The adaptive-device pattern from Apple's own sample (✅ VERIFIED,
`Applications/StableDiffusionExample/ContentView.swift:133-151`):

```swift illustrative
public nonisolated let conserveMemory: Bool

init() {
    // this will be true e.g. if the computer has 8G of memory or less
    self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024

    if conserveMemory {
        print("conserving memory")
        loadConfiguration.quantize = true
        Memory.cacheLimit = 1 * 1024 * 1024
        Memory.memoryLimit = 3 * 1024 * 1024 * 1024
    } else {
        Memory.cacheLimit = 256 * 1024 * 1024
    }
}
```

**Read `Memory.memoryLimit` before you set it.** That is the copyable idea: MLX has already seeded it
from the device's recommended working set, so it is a free device-class probe that works on iOS,
macOS and visionOS without a `utsname` table.

### 6.4 Measuring: `Memory.snapshot()` and a live HUD

`Memory.snapshot()` returns `activeMemory`, `cacheMemory`, `peakMemory` and supports `delta(_:)`.
Apple's `DeviceStat` is the whole HUD in 30 lines (✅ VERIFIED,
`Applications/LLMEval/ViewModels/DeviceStat.swift`, whole file):

```swift prelude:external-module
// Copyright © 2025 Apple Inc.

import Foundation
import MLX

@Observable
final class DeviceStat: @unchecked Sendable {

    @MainActor
    var gpuUsage = Memory.snapshot()

    private let initialGPUSnapshot = Memory.snapshot()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateGPUUsages()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func updateGPUUsages() {
        let gpuSnapshotDelta = initialGPUSnapshot.delta(Memory.snapshot())
        DispatchQueue.main.async { [weak self] in
            self?.gpuUsage = gpuSnapshotDelta
        }
    }
}
```

Inject with `ContentView().environment(DeviceStat())` and read with
`@Environment(DeviceStat.self) private var deviceStat`. Note the 2-second interval — not 1 Hz, not
per-token. Sampling memory is not free.

⚠️ **`Memory.snapshot()` is MLX's view, not the process's view.** It knows about MLX's allocator and
nothing about your images, your Core Data stack, or the JPEG you just decoded. On iOS the number
jetsam cares about is `phys_footprint`, which MLX cannot see. §6.7 covers that.

Calibrating what to expect: `MLXLMCommon`'s own `wired-memory.md` publishes measured deltas for two
models (✅ VERIFIED, `Documentation.docc/wired-memory.md:53-64`). These are **Apple-published**
figures from the package's documentation; the article says only *"local measurements"* and names no
hardware or OS build, so treat the hardware attribution as unknown:

| Model | Sum of `nbytes` | Tensor file total | Active memory after load |
|---|---:|---:|---:|
| Qwen3-4B-Sky-High-Hermes-4bit | 2,262,535,712 | 2,262,637,937 | 2,264,337,376 |
| Qwen3-Next-80B-A3B-Instruct-MLX-4bit | 44,844,060,160 | 44,844,286,608 | 44,844,101,616 |

The conclusion Apple draws is the useful part (verbatim): *"These examples suggest that **`nbytes` is
a reliable basis** for a reservation ticket when you can load the model, and file-size estimates are
a close approximation when you cannot."* The gap between disk size and resident size is **under 0.01%**
in both cases. That is a much tighter relationship than the GGUF world, and it means **your
first-order memory model can be "file size on disk"** — with everything else (KV cache, workspace)
budgeted separately.


### 6.5 Wired memory: the part with a dedicated reference

"Wired" memory is memory the kernel may not page out. For inference this matters because weights
that get paged out mid-generation turn a 30 tok/s model into a slideshow. MLX exposes a
process-wide wired limit; `MLXLMCommon` adds LLM-shaped policy on top.

The division of labour is explicit (✅ VERIFIED, `Documentation.docc/wired-memory.md:1-10`, verbatim):

> MLXLMCommon exposes wired memory policies and tickets to help coordinate a single process-wide
> wired memory limit during inference. Policies decide whether work should be admitted and what
> wired limit is needed; tickets represent active or reserved memory usage and are registered with
> the `WiredMemoryManager`.
>
> For a full system overview (manager, policies, tickets, hysteresis, and usage patterns), see the
> MLX wired memory article in the upstream `mlx-swift` repository.

So: **`WiredMemoryManager`, `WiredMemoryTicket` and the `WiredMemoryPolicy` protocol come from
`mlx-swift`; the four concrete policies come from `MLXLMCommon`.** ✅ VERIFIED,
`Libraries/MLXLMCommon/WiredMemoryPolicies.swift`.

**The four policies** (✅ VERIFIED, read from `WiredMemoryPolicies.swift` this session):

| Policy | Limit formula | Admission |
|---|---|---|
| `WiredSumPolicy(cap: Int? = nil)` | `clamp(baseline + sum(activeSizes))` | denies if projected > cap |
| `WiredMaxPolicy()` | `max(baseline, max(activeSizes))` | always admits |
| `WiredFixedPolicy(limit: Int)` | `bytes` while any ticket is active | always admits |
| `WiredBudgetPolicy(baseBytes: Int, cap: Int? = nil, id: UUID = UUID())` | `clamp(baseline + baseBytes + sum(activeSizes))` | denies if projected > cap |

`WiredSumPolicy`'s implementation, read verbatim this session, shows exactly what `clamp` does:

```swift prelude:guide-context
public struct WiredSumPolicy: WiredMemoryPolicy, Hashable, Sendable {
    public let cap: Int?
    public init(cap: Int? = nil) { self.cap = cap }

    public func limit(baseline: Int, activeSizes: [Int]) -> Int {
        let sum = activeSizes.reduce(0, +)
        return clamp(baseline + sum)
    }

    public func canAdmit(baseline: Int, activeSizes: [Int], newSize: Int) -> Bool {
        let projected = baseline + activeSizes.reduce(0, +) + max(0, newSize)
        return clamp(projected) == projected
    }

    private func clamp(_ value: Int) -> Int {
        if let cap { return min(value, max(0, cap)) }
        if let maxBytes = recommendedWorkingSetBytes() { return min(value, maxBytes) }
        return value
    }
}
```

with

```swift prelude:guide-context
private func recommendedWorkingSetBytes() -> Int? {
    #if canImport(Metal)
    GPU.maxRecommendedWorkingSetBytes()
    #else
    nil
    #endif
}
```

Note the elegance of `canAdmit`: admission is *denied* precisely when clamping would change the
number — i.e. when the projection exceeds the cap.

**Ticket kinds.** ✅ VERIFIED, `skills/mlx-swift-lm/references/wired-memory.md:37-46`:

> - `.active`: contributes while inference is actively running.
> - `.reservation`: tracks long-lived budgets (for example model weights) without keeping limit
>   elevated when no active inference exists.

```swift prelude:guide-context
let reservation = policy.ticket(size: weightBytes, kind: .reservation)
let inference = policy.ticket(size: kvAndWorkspaceBytes, kind: .active)
```

⚠️ **Two `ticket(...)` spellings exist in this repo and one of them is stale.** ✅ VERIFIED by grep
this session:

- `policy.ticket(size:kind:)` — used in `WiredMemoryPolicies.swift`'s own doc comments (four times),
  in three skill reference files, and in `SKILL.md:251`.
- `policy.ticket(size:)` — used in `Libraries/MLXLLM/Documentation.docc/using-model.md:137`,
  `Libraries/MLXLMCommon/README.md:242` and `:275`, and `SKILL.md:344`.

The source-of-truth doc comments sit next to the implementation and use `kind:`. **Write
`ticket(size:kind:)`.** 🟡 RECONSTRUCTED on whether `kind:` has a default value (which would make
both spellings valid simultaneously) — `WiredMemoryTicket` lives in `mlx-swift`, which we could not
read this session. **SAFE DEFAULT: always pass `kind:` explicitly.** It is more readable anyway, and
the distinction between a weight *reservation* and an *active* inference budget is exactly the thing
you want visible at the call site.

**Wiring a ticket into generation.** The `wiredMemoryTicket:` parameter appears on every generation
entry point (✅ VERIFIED, `Evaluate.swift` and `ModelContainer.swift:184-208`):

```swift prelude:guide-context
let policy = WiredSumPolicy(cap: 12 * 1024 * 1024 * 1024)
let ticket = policy.ticket(size: estimatedBytes, kind: .active)

let lmInput = try await modelContainer.prepare(input: UserInput(prompt: "Summarize this"))
let stream = try await modelContainer.generate(
    input: lmInput,
    parameters: GenerateParameters(),
    wiredMemoryTicket: ticket
)
```

✅ VERIFIED, `skills/mlx-swift-lm/references/wired-memory.md:25-35`. Internally the generation loop
wraps the whole iteration in `await WiredMemoryTicket.withWiredLimit(ticket) { … }` when a ticket is
supplied (✅ VERIFIED, `Evaluate.swift:1867-2001`).

**On CPU or unsupported backends**, keep the policy math without attempting to change a wired limit
that does not exist (✅ VERIFIED, `Documentation.docc/wired-memory.md:101-105`):

```swift prelude:guide-context
await WiredMemoryManager.shared.updateConfiguration { configuration in
    configuration.policyOnlyWhenUnsupported = true
}
```

The article adds: *"Policy-only mode defaults to `true` on unsupported backends"* — so this is
usually belt-and-braces rather than required.

**Debug event stream** (✅ VERIFIED, `skills/.../wired-memory.md:103-113`) — in DEBUG builds only;
release is a no-op:

```swift prelude:guide-context
Task {
    for await event in WiredMemoryManager.shared.events() {
        print(event)
    }
}
```

### 6.6 Sizing the ticket: measure, don't guess

`MLXLMCommon` ships a measurement helper precisely so you do not have to model this analytically.
✅ VERIFIED, `WiredMemoryUtils.swift`:

```swift illustrative
public struct WiredMemoryMeasurement: Sendable {
    public let weightBytes, kvBytes, workspaceBytes, peakActiveBytes, tokenCount, prefillStepSize: Int
    public var totalBytes: Int
}
public enum WiredMemoryUtils {
    public static func tune(…)  // 3 overloads: tokens, LMInput, UserInput
}
```

The end-to-end recipe, ✅ VERIFIED verbatim from `skills/mlx-swift-lm/references/wired-memory.md:66-79`:

```swift prelude:guide-context
let context = try await LLMModelFactory.shared.load(configuration: config)
let parameters = GenerateParameters(maxTokens: 128, prefillStepSize: 512)

let measurement = try await WiredMemoryUtils.tune(
    context: context,
    tokenCount: 2048,
    parameters: parameters
)

let baseBytes = measurement.weightBytes + measurement.workspaceBytes
let policy = WiredBudgetPolicy(baseBytes: baseBytes)
let ticket = policy.ticket(size: measurement.kvBytes, kind: .active)
```

and for a VLM, use the overload that takes real media so image and video tensors are counted
(✅ VERIFIED, same file, `:85-91`):

```swift prelude:guide-context
let measurement = try await WiredMemoryUtils.tune(
    userInput: userInput,
    context: context,
    parameters: parameters
)
```

If you cannot afford to load the model to measure it, the two analytic fallbacks are published.
**Weights**, ✅ VERIFIED, `Documentation.docc/wired-memory.md:21-27`:

```swift prelude:guide-context
let context = try await LLMModelFactory.shared.load(configuration: config)
let weightBytes = context.model
    .parameters()
    .flattened()
    .reduce(0) { $0 + $1.1.nbytes }
```

**KV cache**, ✅ VERIFIED, `wired-memory.md:118-128`:

```
elements per token per layer = 2 * kvHeads * headDim
layer elements = tokens * elements per token per layer
layer bytes = layer elements * bytesPerElement
total KV bytes = layer bytes * numAttentionLayers
```

with `bytesPerElement` = 2 for FP16/BF16, 1 for INT8, 0.5 for INT4.

**Prefill workspace** — transient but often dominant, ✅ VERIFIED, `wired-memory.md:150-163`, for a
single attention layer at chunk size `L`:

```
Q      = B * H   * L * D
K      = B * Hkv * L * D
V      = B * Hkv * L * D
Scores = B * H   * L * L
Output = B * H   * L * D
```

The `Scores` term is `L²`. That is why `prefillStepSize` is the lever that controls peak memory
during a long prompt, and why chunked prefill exists at all. `MLXVLM`'s README states the
consequence bluntly (✅ VERIFIED, quoted in the research note): *"Single-pass prefill allocates
transient buffers proportional to prompt length and causes OOM on long prompts."*

Apple's practical guidance, ✅ VERIFIED, `wired-memory.md:84-91` and `:165-179`:

> - If you **can load**: compute `nbytes` once at load time and reuse it for the model's lifetime.
> - If you **cannot load**: sum tensor file sizes as a proxy.
> - Add a **small fixed margin** (e.g., 16-64 MB) to cover allocator overhead and minor variance.
>
> In MLXLMCommon, most callers will **create a single ticket** and run `generate()` inside the ticket
> scope. In that case, budget the ticket for the **peak** expected usage (weights + KV cache +
> prefill workspace). If you already created a **separate reservation ticket** for weights, then the
> inference ticket should cover **KV cache + prefill workspace** only.

Hybrid and MoE models need a layer-by-layer sum because they mix attention and SSM layers; Apple
publishes an approximation for the SSM side (✅ VERIFIED, `wired-memory.md:130-147`):

```
convState elements = B * (convKernelSize - 1) * convDim
convDim = (keyHeadDim * numKeyHeads) * 2 + (valueHeadDim * numValueHeads)
state elements = B * numValueHeads * valueHeadDim * keyHeadDim
linear layer bytes = (convState elements + state elements) * bytesPerElement
total linear bytes = linear layer bytes * numLinearLayers
```

### 6.7 What jetsam looks like, and how to see it coming

⚠️ **SILENT FAILURE — the loudest one in this guide, because there is no signal at all.** On iOS,
exceeding your process memory limit does not throw, does not call `applicationDidReceiveMemoryWarning`
reliably, and does not run your `deinit`. The process is killed by the kernel (`jetsam`). In the
Xcode debugger you get "Message from debugger: Terminated due to memory issue". On a user's device
you get a crash report your analytics may not even receive, and a one-star review that says "it just
closes".

`Memory.snapshot()` will not save you, because it reports **MLX's allocator**, not the process
footprint the kernel measures. You need `phys_footprint` and `os_proc_available_memory`.

The following is **community-measured**, preserved in the
[frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) — a shipping third-party
iOS LLM app. It is the best-documented example of this problem in the corpus and none of it is
Apple-sanctioned. The C shim (`Noema/GGUFScanner.c`):

```c
size_t app_memory_footprint(void) {
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self_, TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (size_t)info.phys_footprint;
}
size_t app_available_memory(void) {
#if defined(TARGET_OS_OSX) && TARGET_OS_OSX
    /* host_statistics64 HOST_VM_INFO64: free_count + inactive_count, × host_page_size */
#else
    size_t avail = os_proc_available_memory();
#endif
    return avail;
}
```

consumed from Swift with `@_silgen_name` in four different files:

```swift compile:27
@_silgen_name("app_available_memory") fileprivate func c_app_available_memory() -> UInt
@_silgen_name("app_memory_footprint") fileprivate func c_app_memory_footprint() -> UInt
```

The reconstruction that makes this actionable, also community-measured:

```swift illustrative
static func liveProcessMemoryLimitBytes(liveAvailable: Int64?, currentFootprint: Int64?) -> Int64?
    // = liveAvailable + currentFootprint  (reconstructs the process allocation limit)
```

i.e. **`os_proc_available_memory() + phys_footprint` is your actual process budget**, discovered at
runtime, no device table needed. The same source states the principle verbatim:

> A positive `os_proc_available_memory()` reading is AUTHORITATIVE on iOS and is never reduced by
> the static device table.

For reference — and to calibrate expectations rather than to hardcode — that app also keeps a
per-device table mapping `utsname().machine` to a budget. Community-measured, 2026-era rows:

```
"iPhone17,5": ("iPhone 16e",        "8 GB",  "~7 GB", 7000 MiB)
"iPhone18,3": ("iPhone 17",         "8 GB",  "~7 GB")
"iPhone18,1": ("iPhone 17 Pro",    "12 GB", "~11 GB")
"iPhone18,2": ("iPhone 17 Pro Max","12 GB", "~11 GB")
"iPhone18,4": ("iPhone Air",       "12 GB", "~11 GB")
"RealityDevice14,1": Apple Vision Pro "16 GB", "~15 GB", 15000 MiB
```

plus `conservativeLimitBytes()` = `limitBytes − 512 MiB`, floored at 0. **Do not copy the table** —
it is stale the day a new device ships. Copy the *fallback structure*: live reading when available,
table only as a floor.

The single most valuable sentence in that entire codebase, verbatim, on why allocation headroom is
not enough:

> Allocation headroom alone is insufficient on unified memory: mmap-backed weights become resident
> as inference touches them. **Device testing on 6 GB-class process limits shows that allowing a
> broad logical overcommit can launch but then OOM at large contexts.** Enforce the same measured
> working-set ceiling used by the recommendation UI before calling a configuration a fit.

Translated for MLX Swift: **a model that loads is not a model that runs.** Weights load, then the KV
cache grows with context, then prefill allocates an `L²` scores buffer. Your fit test must include
all three (§6.6), and it must be re-checked when the user increases context length.

### 6.8 A pressure ladder you can actually copy

Still community-measured, from the same app: a hysteretic governor that samples headroom and fires
graded responses. The design is more valuable than the specific numbers.

```swift illustrative
actor OverfitMemoryGovernor {
    static let warnThreshold      = 0.12
    static let pressureThreshold  = 0.08
    static let criticalThreshold  = 0.05
    static let emergencyThreshold = 0.03
    static let recoveryFactor     = 1.5     // re-arm only after headroom > threshold × 1.5

    init(availableMemory: @escaping @Sendable () -> UInt64,
         footprint:       @escaping @Sendable () -> UInt64,
         applyPressure:   @escaping @Sendable (Int32) -> Void,
         onCritical:      @escaping @Sendable () -> Void,
         onEmergency:     @escaping @Sendable () -> Void,
         pollIntervalNanoseconds: UInt64 = 250_000_000)

    func prepare(totalBudget: UInt64)   // arms without polling (tests use pollOnce())
    func start(totalBudget: UInt64)
    func stop()
    func pollOnce()
}
```

`fraction = available / totalBudget`, where `totalBudget` is the reconstructed limit from §6.7 at
session start. Levels fire **once** and re-arm only above `threshold × 1.5` — that hysteresis is the
whole point, because without it a governor oscillates at the boundary and spends its time freeing
and re-allocating.

Four things to steal:

1. **Inject the readers.** `availableMemory` and `footprint` are closures, which is what makes the
   ladder deterministically testable (that app has `OverfitMemoryGovernorTests` driving it with
   `pollOnce()`).
2. **Poll at 4 Hz, not per token.** 250 ms is frequent enough to catch a runaway prefill and cheap
   enough to ignore.
3. **Graded responses, not one panic button.** In that app, `onCritical` cancels queued work but
   lets generation continue; `onEmergency` stops the runtime outright, with the comment
   *"Crash prevention beats grace."*
4. **Surface it.** A live pressure meter sampled at 1 Hz, with a four-level enum:

```swift illustrative
enum MemoryPressureLevel { case comfortable, elevated, high, critical }

var pressure: MemoryPressureLevel {
    if thermalState == .critical { return .critical }
    if thermalState == .serious  { return .high }
    if let availableBytes {
        if availableBytes <  256 MiB { return .critical }
        if availableBytes <  512 MiB { return .high }
        if availableBytes < 1024 MiB { return .elevated }
    }
    switch budgetProgress {           // footprint / conservativeBudget
    case 0..<0.70:    .comfortable
    case 0.70..<0.88: .elevated
    case 0.88..<0.98: .high
    default:          .critical
    }
}
```

Note that **thermal state short-circuits the memory calculation**. That is not a category error: on
a thermally throttled device, generation slows, contexts live longer, and pressure compounds. The
same app applies a separate `GenerationPowerPolicy` that halves thread limits under
`.serious` thermal state and disables warmup, and blocks its most memory-hungry mode outright at
`.critical` — *"Paged decode adds sustained storage and CPU traffic on top of inference, so thermals
gate it harder than a resident launch."* All community-measured.

### 6.9 Backgrounding, unloading, and download behaviour

Three production behaviours that are invisible in a sample app and mandatory in a shipping one. All
community-measured from the [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) unless marked.

**1. Unload big models when backgrounded.** The policy, verbatim in shape:

```swift illustrative
static let defaultInactiveDelaySeconds: TimeInterval = 120
static let largeWorkingSetThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2 GiB
// threshold = max(2 GiB, memoryBudgetBytes / 3)
// keep reasons, in order: "policy disabled", "scene active", "no active chat model",
//   "generation in progress", "send in progress", "routing in progress", "no local runtime format"
```

with an explicitly enumerated keep-list, and — crucially — **re-evaluation every 1 second while a
turn is still streaming**:

> If backgrounding happened during routing/generation, the first policy pass intentionally keeps the
> model. Reevaluate until the turn finishes so a large GGUF does not remain resident for the entire
> suspension.

That is the subtle part. You cannot unload mid-generation, so the first policy pass must decline —
and if you do not re-run it, the model stays resident for the whole suspension and you get jetsammed
while backgrounded, which shows up to the user as "the app restarts every time I switch away".

**2. Verify that unloading worked.**

```swift compile:27
enum ModelUnloadVerifier {
    static let defaultRecoveryThresholdBytes: Int64 = 32 * 1024 * 1024
    // Status: .recovered (released ≥ 32 MiB) | .unchanged | .increased | .unavailable
}
```

The unload sequence: snapshot memory, detach the client on the main actor, await teardown off-actor,
**sleep 500 ms**, re-sample, log. The 500 ms is not superstition — MLX's `Memory.clearCache()` frees
the recycle pool but `phys_footprint` trails it by a noticeable interval, a behaviour independently
catalogued in the cross-repo issue mining (*"`mx.clear_cache()` does not free live buffers, only the
recycle pool; and `phys_footprint` trails it by seconds"* — community-measured).

The race that verification exposed, verbatim:

> Memory/background policy must not race a send between an idle check and client detachment.

Their fix: perform the idle check and the client detachment in **one `MainActor.run` transaction**,
guarded by a generation UUID.

**3. Downloads need a background `URLSession`, and that changes their behaviour.** The documented
iOS gotcha, verbatim from that app's `TaskRecord`:

> `createdInBackground`: Whether the task was created while the app was not active (**such
> background-session tasks are discretionary — the system ignores `isDiscretionary=false` for
> them**).

That single sentence is why style 1 (§3.2) exists. A `Downloader` built on `HubClient` does what
`HubClient` does; a `Downloader` you wrote can migrate tasks between a foreground
`URLSessionConfiguration.default` and a background `URLSessionConfiguration.background(withIdentifier:)`
on lifecycle transitions, coalesce progress through a `ProgressThrottler` at 2 Hz (*"Two updates per
second keeps progress/speed readable while preventing parallel model shards from flooding the main
actor with dozens of callbacks per second"*), and adopt a `BGContinuedProcessingTask` on iOS 26 to
keep a multi-gigabyte transfer alive with a system-visible progress UI.

Two implementation traps from that codebase worth repeating because they cost real debugging time:

- **URLSession fires the cancel callback before `didCompleteWithError`**, so migrating a task
  between sessions looks like a download failure unless you track suppressed cancellations.
- **Two resume kinds must not be mixed.** Range-header resume makes `resumeOffset` additive
  (`totalBytesWritten + resumeOffset`); resume-data resume yields absolute totals already. Add both
  and your progress bar exceeds 100%.

And on iOS 26's `BGContinuedProcessingTask`, one detail that is a hard crash rather than a bug:
`BGTaskScheduler` **crashes on duplicate registration**, so each download batch registers a *fresh
UUID identifier*, enabled by a wildcard in `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.noema.download.maintenance</string>
  <string>arminproducts.Noema.download.continue.*</string>   <!-- wildcard identifier for CPT -->
</array>
```

Community-measured. Cross-reference [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) for the
shipping-and-operating view of all three.

### 6.10 Memory checklist

- [ ] `com.apple.developer.kernel.increased-memory-limit` in your entitlements.
- [ ] `Memory.cacheLimit` set once, deliberately, **after** your first model load if a library also
      sets it.
- [ ] `Memory.memoryLimit` **read** before being set, to classify the device.
- [ ] A fit test that includes weights **+ KV cache + prefill workspace**, re-run when context
      length changes.
- [ ] `phys_footprint` / `os_proc_available_memory` monitoring, not just `Memory.snapshot()`.
- [ ] Generation cancelled on `scenePhase != .active`, and awaited (§5.6).
- [ ] Large models unloaded on background, with re-evaluation while a turn streams.
- [ ] Unload verified by measurement, not assumed.
- [ ] A wired-memory ticket sized from `WiredMemoryUtils.tune`, not from a guess.


---

## 7. Media input for VLMs

### 7.1 The input types

Everything a VLM eats goes through `UserInput`. ✅ VERIFIED, read this session from
`Libraries/MLXLMCommon/UserInput.swift`:

```swift prelude:guide-context
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

The media enums (✅ VERIFIED, `UserInput.swift:79-173`):

```swift prelude:guide-context
public enum Image {
    #if canImport(CoreImage)
    case ciImage(CIImage)
    #endif
    case url(URL)
    case array(MLXArray)
    public func asCIImage() throws -> CIImage
}

public enum Video {
    #if canImport(AVFoundation)
    case avAsset(AVAsset)
    #endif
    case url(URL)
    case frames([VideoFrame])
}

public enum Audio { case url(URL); case array(MLXArray) }
public struct VideoFrame { public let image: Image; public let timeStamp: CMTime }
```

The `#if canImport(...)` guards are there because this package compiles on Linux
(`Libraries/MLXLMCommon/Linux/` contains `CoreGraphics.swift`, `CoreMedia.swift` and friends —
✅ VERIFIED, commit `65e28c2`, *"Make MLXLLM compilable on Linux (#321)"*). On Apple platforms all
cases exist.

And the per-request processing knobs (✅ VERIFIED, `UserInput.swift:189-207`):

```swift prelude:guide-context
public struct Processing: Sendable {
    public var resize: CGSize?
    public var audio = AudioProcessing()
    public var minPixels: Int?      // per-call override of model min_pixels
    public var maxPixels: Int?      // per-call override of model max_pixels
    public init(resize: CGSize? = nil, minPixels: Int? = nil, maxPixels: Int? = nil)
}
```

⚠️ **`ChatSession`'s default `processing` resizes every image to 512×512.** ✅ VERIFIED — the common
initialiser tail is `processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512))`
(`ChatSession.swift`). Apple's own `MLXChatExample` overrides it to 1024×1024 on the raw `UserInput`
path (✅ VERIFIED, `MLXService.swift`: `UserInput(chat: chat, processing: .init(resize: .init(width: 1024, height: 1024)))`).
If your OCR-ish task is failing on small text, this default is the first thing to change — and note
that it is *not* silent in the sense of being hidden, but it is silent in the sense that nothing
tells you your 4032×3024 photo became 512×512 before the model ever saw it.

There is a subtle initialiser trap documented in the source itself (✅ VERIFIED, `UserInput.swift`,
verbatim comment): `// note: prompt.didSet is not triggered in init`. Every initialiser therefore
re-derives `images`/`videos`/`audios` manually. If you construct a `UserInput` and then mutate
`prompt` afterwards, the media arrays **are** re-derived (via `didSet`); if you set media directly
they are not merged into the chat. Prefer the initialisers.

### 7.2 The processor pipeline

`UserInputProcessor` is a one-method protocol (✅ VERIFIED, `UserInput.swift:450-452`):

```swift prelude:guide-context
public protocol UserInputProcessor: Sendable {
    func prepare(input: UserInput) async throws -> LMInput
}
```

Its job, per `MLXLMCommon`'s porting documentation (✅ VERIFIED, `porting.md`, summarised in the
research note): sRGB tone-curve conversion, apply the user's `Processing`, resample, normalize,
convert to `MLXArray`, and **inject the model's image placeholder tokens**. That last step is why
you cannot hand a VLM a bare pixel tensor and a text prompt — the token stream has to interleave
correctly, and only the model-specific processor knows the layout.

The output is `LMInput` (✅ VERIFIED, `Libraries/MLXLMCommon/LanguageModel.swift`):

```swift illustrative
public struct LMInput {
    public let text: Text
    public let image: ProcessedImage?
    public let video: ProcessedVideo?
    public let audio: ProcessedAudio?

    public struct ProcessedImage { public let pixels: MLXArray; public let positionIds: MLXArray?; public let frames: [THW]? }
}
public struct THW: Sendable { public let t, h, w: Int; … }
```

`MLXVLM.MediaProcessing` is the toolbox the processors are built from — 571 lines, and its public
surface is worth knowing because you will need pieces of it if you preprocess images yourself
(✅ VERIFIED, `Libraries/MLXVLM/MediaProcessing.swift`, public-symbol listing):

```swift illustrative
public struct ProcessedFrames { public let frames: [MLXArray]; timestamps: [CMTime]; totalDuration: CMTime }

public enum MediaProcessing {
    static func inSRGBToneCurveSpace(_ image: CIImage) -> CIImage
    static func inLinearToneCurveSpace(_ image: CIImage) -> CIImage
    static func bestFit(_ size: CGSize, in other: CGSize) -> CGSize
    static func resampleLanczos(_ image: CIImage, to size: CGSize) -> CIImage
    static func resampleBicubic(_ image: CIImage, to size: CGSize) -> CIImage
    static func normalize(_ image: CIImage, mean:(CGFloat,CGFloat,CGFloat), std:(CGFloat,CGFloat,CGFloat)) -> CIImage
    static func asMLXArray(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> MLXArray
    static func centerCrop(_ image: CIImage, size: CGSize) -> CIImage
    static func fitIn(_ size: CGSize, shortestEdge: Int) -> CGSize
    static func fitIn(_ size: CGSize, longestEdge: Int) -> CGSize
    static func padToSquare(_ image: CIImage, backgroundColor: CIColor = .black) -> CIImage
    static func apply(_ image: CIImage, processing: UserInput.Processing?) -> CIImage
    static func asCIImageSequence(_ asset: AVAsset, samplesPerSecond: Int) async throws -> …
    static func asProcessedSequence(…)   // 4 overloads
}
```

plus `CIImage` conveniences: `.resampled(to:method:)`, `.toSRGB()`, `.toLinear()`,
`.normalized(mean:std:)`, `.paddingToSquare(backgroundColor:)`, `.asMLXArray(colorSpace:)`.

**There is no orientation function in that list.** Note it now; §7.4 is about exactly that.

The errors a VLM path can throw (✅ VERIFIED, `MLXVLM`): `VLMError.imageRequired`, `.maskRequired`,
`.singleImageAllowed`, `.singleVideoAllowed`, `.singleMediaTypeAllowed`,
`.imageProcessingFailure(String)`, `.processing(String)`, `.noVideoTrackFound`, `.videoNotDecodable`.
`.singleImageAllowed` and `.singleMediaTypeAllowed` are the ones you will hit: **many VLMs accept
exactly one image and refuse to mix an image with a video in one turn.** Check before you build a
multi-attachment UI.

⚠️ One processor-selection gotcha that produces wrong output rather than an error: the VLM factory
**prefers `preprocessor_config.json` over `processor_config.json`**, and it overrides the declared
processor class for two model types (✅ VERIFIED, `Libraries/MLXVLM/VLMModelFactory.swift:419-424`):

```swift compile:27
let processorTypeOverrides: [String: String] = [
    "mistral3": "Mistral3Processor",
    "gemma4_unified": "Gemma4UnifiedProcessor",
]
```

with the source comment *"Mistral3 models ship with 'PixtralProcessor' in their config but need
Mistral3Processor to handle spatial merging correctly."* If you convert your own VLM checkpoint and
copy someone else's `preprocessor_config.json`, this is how you get plausible-but-wrong image
handling.

### 7.3 Video

Video arrives as `UserInput.Video` and is sampled into frames. The sampling entry point is
`MediaProcessing.asProcessedSequence(...)` (four overloads) and
`asCIImageSequence(_:samplesPerSecond:)`. ✅ VERIFIED, `MediaProcessing.swift:292` and `:428-519`.

Two things to know:

1. **Frames go through `Image.asCIImage()` one at a time** (✅ VERIFIED,
   `MediaProcessing.swift:451` and `:519` — `ciImages.append(try frame.image.asCIImage())`). So
   every caveat in §7.4 applies per frame.
2. There is a rounding note in the source about frame counts (✅ VERIFIED,
   `MediaProcessing.swift:428`, verbatim): *"Note: the round was not present in
   `asCIImageSequence`, so we may now be passing 1 more frame to Qwen depending on video duration."*
   If you are comparing Swift output against Python `mlx-vlm` frame-by-frame, that off-by-one is a
   known, deliberate difference — not a bug in your code.

The package's own tests carry video fixtures (`Tests/MLXLMTests/Resources/1080p_30.mov` and
`audio_only.mov`; ✅ VERIFIED from `Package.swift`'s test target resources), which is a useful signal
that video is genuinely exercised rather than aspirational.

### 7.4 ⚠️ EXIF orientation — the bug Apple fixed in their own sample

**The symptom:** a user takes a portrait photo on iPhone, picks it in your app, and the VLM
describes a sideways scene. Nothing throws. Confidence is normal. The model is simply looking at a
rotated image.

**The mechanism, verified from source.** `UserInput.Image.url(url)` resolves like this — ✅ VERIFIED,
read this session from `Libraries/MLXLMCommon/UserInput.swift:116-125`:

```swift illustrative
public func asCIImage() throws -> CIImage {
    switch self {
    case .ciImage(let image):
        return image

    case .url(let url):
        if let image = CIImage(contentsOf: url) {
            return image
        }
        throw UserInputError.unableToLoad(url)
    // …
```

That is the entire URL path. **There is no orientation call anywhere in it** — no
`.oriented(...)`, no orientation property read, nothing. Confirmed by grep across
`UserInput.swift` and `MediaProcessing.swift`: zero matches for `orientation`, `exif`, or any
orientation-applying API. Whatever `CIImage(contentsOf:)` does by default is what your VLM sees.

**Apple's fix, in Apple's own sample.** `mlx-swift-examples` commit `378f244` (2026-06-16) is titled
*"MLXChatExample: fix VLM image handling on iOS (PhotosPicker, EXIF, empty assistant trim) (#472)"*
and its body says (✅ VERIFIED, transcribed in the research note):

```
- Use custom Transferable types for reliable PhotosPicker loading
- Normalize image orientation before saving (CIImage ignores EXIF)
- Exclude trailing empty assistant message from model input
```

and the in-code comment at the fix site is unambiguous (✅ VERIFIED, `ChatView.swift`, verbatim):

```swift illustrative
// Normalize orientation so pixels match the display orientation.
// UIImage.jpegData() only writes an EXIF tag but CIImage(contentsOf:)
// does not apply it, so the VLM would receive a rotated image.
```

⚠️ **Conflicting evidence, reported rather than smoothed over.** A separate research pass over
Apple's `coreai-models` repository asserts the *opposite* — that `CIImage(contentsOf:)` **does** apply
EXIF orientation while `CGImageSourceCreateImageAtIndex` does not. Both notes are in this corpus and
they cannot both be right.

How to weigh them: the `mlx-swift-examples` claim comes from a **fix commit** — someone observed
rotated images, changed code, and the rotation stopped. That is empirical evidence about a specific
2026 toolchain. The Core AI note's claim is an inference recorded during a source read, not a
measurement. Under this series' precedence rules, compiling first-party code that was written *in
response to the observed behaviour* outranks an unmeasured assertion. 🔴 **GAP on the underlying
CoreImage semantics** — we did not run the experiment ourselves, and the behaviour may differ by
loading path (file URL vs `Data`), by whether an options dictionary is supplied, and by OS version.
**What would resolve it:** a five-line test that loads a known EXIF-rotated JPEG through
`CIImage(contentsOf:)` and prints `extent`, run on the OS you ship.

**SAFE DEFAULT, and it is safe under either reading: normalise the pixels yourself before the image
reaches MLX.** Re-rendering an already-upright image is a no-op in correctness terms and costs one
draw. Here is Apple's fix, ✅ VERIFIED verbatim from `Applications/MLXChatExample/ChatView.swift`
(the surrounding `.onChange(of: photosPickerItems)` block):

```swift prelude:guide-context
if let picked = try? await item.loadTransferable(type: PickedImage.self),
    let uiImage = UIImage(data: picked.data)
{
    // Normalize orientation so pixels match the display orientation.
    // UIImage.jpegData() only writes an EXIF tag but CIImage(contentsOf:)
    // does not apply it, so the VLM would receive a rotated image.
    let renderer = UIGraphicsImageRenderer(size: uiImage.size)
    let oriented = renderer.image { _ in
        uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
    }
    if let jpegData = oriented.jpegData(compressionQuality: 0.9) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try? jpegData.write(to: url)
        vm.addMedia(.success(url))
    }
}
```

The key line is `uiImage.draw(in:)` inside a `UIGraphicsImageRenderer`. `UIImage` carries orientation
as *metadata*; drawing it applies that metadata and produces an upright pixel buffer. Writing that
buffer as JPEG produces a file whose pixels need no interpretation.

**This is not an MLX quirk.** The same research corpus records, about Apple's own `coreai-models`
Swift tree: *"Zero `CVPixelBuffer` handling and **zero EXIF/orientation handling** in the entire
non-LLM Swift tree. Image orientation is the caller's problem."* — and separately, within one
repository, *"the same JPEG can be preprocessed two different ways depending on which entry point you
use. This is a real, unfixed inconsistency."* So the correct mental model for 2026 is:

> **Orientation is the caller's job across Apple's entire on-device vision stack.** No framework
> normalises it for you. Normalise once, at the boundary where a user picks an image, and never
> think about it again.

### 7.5 PhotosPicker, done correctly

The same commit fixed a second, independent bug: `loadTransferable(type: Data.self)` is unreliable
against PhotosPicker. The fix is explicit `Transferable` wrappers. ✅ VERIFIED verbatim from
`Applications/MLXChatExample/ChatView.swift`:

```swift illustrative
#if canImport(UIKit)
    import UIKit

    /// Transferable wrapper that explicitly requests image content type from PhotosPicker.
    private struct PickedImage: Transferable {
        let data: Data

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(importedContentType: .image) { data in
                PickedImage(data: data)
            }
        }
    }

    /// Transferable wrapper for video content from PhotosPicker.
    private struct PickedVideo: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .movie) { receivedFile in
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "\(UUID().uuidString).\(receivedFile.file.pathExtension)")
                try FileManager.default.copyItem(at: receivedFile.file, to: dest)
                return PickedVideo(url: dest)
            }
        }
    }
#endif
```

⚠️ **`receivedFile.file` points into a sandboxed temporary location that is deleted when the closure
returns.** You must `copyItem` out of it, as above. Keep the URL and you get a file-not-found later,
at generation time, far from the cause.

And the full picker wiring, ✅ VERIFIED verbatim from the same file:

```swift illustrative
#if os(iOS)
    .photosPicker(
        isPresented: $vm.mediaSelection.isShowing,
        selection: $photosPickerItems,
        maxSelectionCount: 1,
        matching: .any(of: [.images, .videos])
    )
    .onChange(of: photosPickerItems) {
        Task {
            for item in photosPickerItems {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                    // …PickedImage + orientation normalisation from §7.4…
                } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    if let picked = try? await item.loadTransferable(type: PickedVideo.self) {
                        vm.addMedia(.success(picked.url))
                    }
                }
            }
            photosPickerItems = []
        }
    }
#else
    .fileImporter(
        isPresented: $vm.mediaSelection.isShowing,
        allowedContentTypes: [.image, .movie],
        onCompletion: vm.addMedia
    )
#endif
```

Note `maxSelectionCount: 1` — consistent with the `VLMError.singleImageAllowed` constraint from §7.2.

**On macOS, `fileImporter` URLs are security-scoped** and must be balanced. ✅ VERIFIED verbatim from
`ChatViewModel.swift:158-188`:

```swift compile:27 imports:SwiftUI
@Observable
class MediaSelection {
    var isShowing = false
    var images: [URL] = [] { didSet { didSetURLs(oldValue, images) } }
    var videos: [URL] = [] { didSet { didSetURLs(oldValue, videos) } }
    var isEmpty: Bool { images.isEmpty && videos.isEmpty }

    private func didSetURLs(_ old: [URL], _ new: [URL]) {
        // the urls we get from fileImporter require SSB calls to access
        new.filter { !old.contains($0) }.forEach { _ = $0.startAccessingSecurityScopedResource() }
        old.filter { !new.contains($0) }.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
```

Doing this in `didSet` on the array is a genuinely nice trick: start/stop are paired by set
difference, so you cannot leak a scope by forgetting a `stop`.

### 7.6 The third bug in the same commit: trailing empty assistant message

Not media, but it ships in the same fix and it bites the raw `UserInput` path. ✅ VERIFIED verbatim
from `Applications/MLXChatExample/Services/MLXService.swift`:

```swift prelude:guide-context
// Exclude trailing empty assistant message so the chat template
// leaves the assistant turn open for generation (matching ChatSession behavior)
var inputMessages = messages
if let last = inputMessages.last, last.role == .assistant, last.content.isEmpty {
    inputMessages.removeLast()
}
```

⚠️ **SILENT FAILURE.** The idiomatic SwiftUI chat pattern appends an empty `.assistant("")`
placeholder so the streaming text has somewhere to go. If you then pass `messages` straight into
`UserInput(chat:)`, the chat template sees a *completed* empty assistant turn and **closes** it — so
the model generates a new turn, or refuses, or emits a role header. `ChatSession` strips it for you;
the raw path does not. Symptom: garbage or empty output only when you use `UserInput` directly, which
makes it look like a model problem.

### 7.7 VLM memory: the two failure modes worth naming

VLM prefill is where iOS memory budgets go to die, and two specific mechanisms account for most of
it. Both are **community-measured**, from the cross-repo issue/PR mining pass; both were fixed
upstream, but they teach you what to look for in a model you port yourself.

**1. Merged-sequence attention makes memory grow as (Σ Lᵢ)² instead of Σ Lᵢ².** In `mlx-swift-lm`
PR **#455** (MERGED 2026-07-22), Qwen3VL merged all images into one attention sequence behind a
dense `[1, L, L]` additive mask. Two images totalling 8140 pads requested a single **33.9 GB** Metal
buffer — past `maxBufferLength` on a 48 GB M4 Pro. The fix was to attend each `cuSeqlens` segment
independently with **no mask** (mathematically identical to a block-diagonal mask).

**2. Odd head dimensions fall out of the fused SDPA kernel, silently.** Qwen3VL's vision tower has
head dim **72** (1152 / 16 heads), outside the fused Metal kernel's supported set, so
`MLXFast.scaledDotProductAttention` **silently falls back** and materialises `numHeads × L² × 2`
bytes. The fix: **zero-pad head dim 72 → 80** so the fused kernel dispatches. Exact, because padded
dimensions contribute nothing to the dot products and `scale` is passed explicitly. The same trick
exists in the repo as `gemma4EnsureFusedSDPA`.

Measured before/after, from that PR (community-measured; hardware named as a 48 GB M4 Pro):

| case | before | after |
|---|---|---|
| single image, 6188 pads | 28.7 GB peak | 12.6 GB peak |
| two images, 8140 pads total | fatal (33.9 GB > maxBufferLength) | 14.2 GB peak |
| two-image prefill wall clock | 59.8 s | 36.3 s |

⚠️ **The generalisable silent failure: fused SDPA coverage is head-dim-gated and the fallback is
silent.** From the same mining pass, the reported coverage is *vector* {64, 96, 128, 256} plus
(192,128), and *full* {64, 80, 128}; anything else materialises a `[B, n_kv, n_rep, qL, kL]` score
tensor. Named victims include Gemma 4 global layers (d=512), Gemma 4 sliding layers (d=256 at
prefill), the Qwen3VL vision tower (d=72), and **any d=96 model**. Community-measured, and the
routing table was quoted from MLX's own `scaled_dot_product_attention.cpp`. If you port a VLM and
prefill memory is inexplicable, check the vision tower's head dim first.

Two smaller VLM fixes worth knowing about because they change *output* rather than memory, both
community-sourced from the same pass: **PR #411** applies the sRGB tone curve in Qwen3VL image
preprocessing (issue #410 — linear-light values made dark content unreadable), and **PR #398**
defaults per-image resolution to a **1,280 vision-token budget** (issue #396 — uncapped resolution
let the ViT allocate tens of GB).


---

## 8. SwiftUI patterns: streaming, cancellation, progress

### 8.1 The minimal streaming view model

Apple's `LLMBasic` is the reference. ✅ VERIFIED verbatim from
`Applications/LLMBasic/ChatModel.swift`:

```swift prelude:guide-context
/// View model for the ChatSession
@MainActor @Observable public class ChatModel {

    private let session: ChatSession

    /// back and forth conversation between the user and LLM
    public var messages = [Chat.Message]()

    private var task: Task<Void, Error>?
    public var isBusy: Bool {
        task != nil
    }

    public init(model: ModelContainer) {
        self.session = ChatSession(
            model,
            instructions: instructions,
            generateParameters: generateParameters)
    }

    public func cancel() {
        task?.cancel()
    }

    public func respond(_ message: String) {
        guard task == nil else { return }

        self.messages.append(.init(role: .user, content: message))
        self.messages.append(.init(role: .assistant, content: "..."))
        let lastIndex = self.messages.count - 1

        self.task = Task {
            var first = true
            for try await item in session.streamResponse(to: message) {
                if first {
                    self.messages[lastIndex].content = item
                    first = false
                } else {
                    self.messages[lastIndex].content += item
                }
            }
            self.task = nil
        }
    }
}
```

Three things this gets right that a hand-rolled version usually gets wrong:

1. **`guard task == nil else { return }`** — one generation at a time. `ChatSession` is not
   thread-safe (§5.4), so a double-tap on Send without this guard is a data race, not just a
   duplicate message.
2. **The `first` flag replaces the `"..."` placeholder** rather than appending to it. Without it your
   first token reads `...Hello`.
3. **`@MainActor` on the whole class.** The `AsyncThrowingStream` yields `String`s, which are
   `Sendable`, so consuming on the main actor is free. Do not be tempted to consume off-actor and hop
   per token — that is strictly more work.

And the view, ✅ VERIFIED verbatim from `Applications/LLMBasic/ContentView.swift`:

```swift prelude:guide-context
struct ContentView: View {
    let loader: ModelLoader
    @State var session: ChatModel?
    @State var error: String?
    @State var prompt = ""
    @FocusState var promptFocused

    var body: some View {
        VStack {
            if let error {
                Text("Error: \(error)")
            } else if !loader.isLoaded {
                ProgressView("Loading", value: loader.progress, total: 1)
            } else if let session {
                ScrollView(.vertical) {
                    ForEach(session.messages.enumerated(), id: \.offset) { _, message in
                        let bold = message.role == .user
                        HStack {
                            Text(message.content).bold(bold)
                            Spacer()
                        }
                        .padding(.bottom, 4)
                    }
                    Spacer()
                    if session.isBusy {
                        // a stop button -- cmd-. to interrupt
                        HStack {
                            Button("Stop", action: { session.cancel() })
                                .keyboardShortcut(".")
                            Spacer()
                        }
                    } else {
                        TextField("Prompt", text: $prompt)
                            .onSubmit(respond)
                            .focused($promptFocused)
                            .onAppear { promptFocused = true }
                    }
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .padding()
        .task {
            do {
                let model = try await loader.model()
                self.session = ChatModel(model: model)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear {
            self.session?.cancel()
        }
    }

    private func respond() {
        session?.respond(prompt)
        prompt = ""
    }
}
```

`.onDisappear { session?.cancel() }` is the minimum viable version of §5.6. It is not sufficient —
`onDisappear` does not fire on backgrounding — but it is necessary.

### 8.2 Not dropping frames

The naive `message.content += chunk` on an `@Observable` object is fine for `LLMBasic` and stops
being fine once your chat view has 200 messages, markdown rendering, and syntax highlighting. Three
mitigations, in increasing order of effort.

**1. `LazyVStack` plus the right scroll anchor.** ✅ VERIFIED verbatim from
`Applications/MLXChatExample/Views/ConversationView.swift`:

```swift prelude:guide-context
ScrollView {
    LazyVStack(spacing: 12) {
        ForEach(messages) { message in
            MessageView(message).padding(.horizontal, 12)
        }
    }
}
.padding(.vertical, 8)
.defaultScrollAnchor(.bottom, for: .sizeChanges)
```

`.defaultScrollAnchor(.bottom, for: .sizeChanges)` is the modifier that gives you auto-follow while
streaming without a `ScrollViewReader` and without a `scrollTo` per token.

**2. Batch the stream.** `Generation` and `TokenGeneration` both ship a static reducer designed for
this (✅ VERIFIED, `Evaluate.swift:1117` and `:1124`, with the doc comment *"Reducer that can be used
with `throttle()` to gather elements into a batch"*):

```swift illustrative
@Sendable public static func collect(_ batch: [Generation]?, _ element: Generation) -> [Generation]
```

That doc comment names `throttle()`, i.e. `swift-async-algorithms`. Apple did not add the dependency
to `mlx-swift-lm` — this is an affordance for *you*. If you already depend on
`swift-async-algorithms`, the shape is:

```swift prelude:external-module
import AsyncAlgorithms

for await batch in stream.throttle(for: .milliseconds(50), reducing: Generation.collect) {
    let text = batch.compactMap(\.chunk).joined()
    guard !text.isEmpty else { continue }
    messages[lastIndex].content += text
}
```

🟡 **RECONSTRUCTED** on that exact `throttle(for:reducing:)` spelling — it is
`swift-async-algorithms` API, not MLX API, and this session did not read that package. The
`Generation.collect` signature and its intent are ✅ VERIFIED. If the spelling has drifted, the shape
(a throttle whose reducer accumulates into `[Generation]`) is what to look for. **SAFE DEFAULT** if
you do not want the dependency: accumulate into a local `String` and assign to the published property
on a timer or every N chunks — Apple's own `LoRAEvaluator` does exactly that with
`if count % evaluateShowEvery == 0 { self.output = output }` (✅ VERIFIED via the research note).

**3. Isolate the streaming text from the rest of the view model.** Community-measured, from
the [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md):

```swift illustrative
@MainActor final class StreamingMessageStore: ObservableObject {
    /// Isolates high-frequency token updates from `ChatVM.objectWillChange`.
    @Published private(set) var activeID: UUID?
    @Published private(set) var visibleText: String = ""
    func begin(id:initialText:) ; func update(_:) ; func finish()
}
```

with the note that this *"is the standard fix for SwiftUI re-rendering the entire chat on every
token."* The principle generalises to `@Observable`: put the fast-changing string on its own object
so only the one bubble that is streaming invalidates.

That app also ships a `StreamChunkMerger` for a problem you will meet the moment you support more
than one backend — some emit **delta** chunks and some emit **cumulative** text:

```swift illustrative
enum StreamChunkMergeMode { case unknown, delta, cumulative }
mutating func deltaToAppend(for newChunk: String, existing: String) -> String
// .unknown: if newChunk.hasPrefix(existing) && longer -> switch to .cumulative
//           else compute suffix/prefix overlap and drop it
```

`mlx-swift-lm` emits **deltas** — `Generation.chunk(String)` is an incremental piece — so you do not
need this for MLX alone. You need it the day you add a second backend.

### 8.3 Cancellation with a visible result

`MLXChatExample` shows the fuller pattern, including marking the message as cancelled.
✅ VERIFIED verbatim from `Applications/MLXChatExample/ViewModels/ChatViewModel.swift:61-136`:

```swift prelude:guide-context
    /// Generates response for the current prompt and media attachments
    func generate() async {
        // Cancel any existing generation task
        if let existingTask = generateTask {
            existingTask.cancel()
            generateTask = nil
        }

        isGenerating = true

        messages.append(.user(prompt, images: mediaSelection.images, videos: mediaSelection.videos))
        messages.append(.assistant(""))

        clear(.prompt)

        generateTask = Task {
            for await generation in try await mlxService.generate(
                messages: messages, model: selectedModel)
            {
                switch generation {
                case .chunk(let chunk):
                    if let assistantMessage = messages.last {
                        assistantMessage.content += chunk
                    }
                case .info(let info):
                    generateCompletionInfo = info
                case .toolCall(let call):
                    break
                }
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await generateTask?.value
            } onCancel: {
                Task { @MainActor in
                    generateTask?.cancel()
                    if let assistantMessage = messages.last {
                        assistantMessage.content += "\n[Cancelled]"
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isGenerating = false
        generateTask = nil
    }
```

Note `try await generateTask?.value` inside `withTaskCancellationHandler` — that is the "await the
task after cancelling" discipline from §5.6, expressed as a SwiftUI idiom. The `onCancel` closure
runs synchronously on the cancelling thread, hence the `Task { @MainActor in … }` hop.

The run/stop button that pairs with it (✅ VERIFIED, `PromptField.swift`):

```swift prelude:guide-context
Button {
    if isRunning { task?.cancel(); removeTask() }
    else { task = Task { await sendButtonAction(); removeTask() } }
} label: {
    Image(systemName: isRunning ? "stop.circle.fill" : "paperplane.fill")
}
.keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
// …
private var isRunning: Bool { task != nil && !(task!.isCancelled) }
```

### 8.4 Model caching across a picker

If your app lets the user switch models, cache containers. ✅ VERIFIED verbatim from
`Applications/MLXChatExample/Services/MLXService.swift`:

```swift prelude:guide-context
/// Cache to store loaded model containers to avoid reloading.
private let modelCache = NSCache<NSString, ModelContainer>()

private func load(model: LMModel) async throws -> ModelContainer {
    // Set GPU memory limit to prevent out of memory issues
    Memory.cacheLimit = 20 * 1024 * 1024

    if let container = modelCache.object(forKey: model.name as NSString) {
        return container
    } else {
        let factory: ModelFactory =
            switch model.type {
            case .llm: LLMModelFactory.shared
            case .vlm: VLMModelFactory.shared
            }

        let downloader = #hubDownloader()
        let loader = #huggingFaceTokenizerLoader()

        let container = try await factory.loadContainer(
            from: downloader,
            using: loader,
            configuration: model.configuration
        ) { progress in
            Task { @MainActor in
                self.modelDownloadProgress = progress
            }
        }

        modelCache.setObject(container, forKey: model.name as NSString)
        return container
    }
}
```

`NSCache<NSString, ModelContainer>` works because `ModelContainer` is a class, and the OS can evict
entries under memory pressure — which is genuinely useful here, since eviction of an unused model is
exactly the behaviour you want.

⚠️ But note two things. First, `NSCache` eviction is **not** coordinated with MLX: dropping the last
reference releases the weights, but `phys_footprint` trails (§6.9). Second, this snippet re-asserts
`Memory.cacheLimit = 20 MB` on **every** load — which is the "libraries stomping the cache limit"
problem from §6.3 in miniature, in Apple's own sample. `mlx-swift-lm`'s FoundationModels adapter
solved it with a run-once `static let`; consider doing the same.

### 8.5 Progress during download versus load

Two distinct phases and users notice when you conflate them.

- **Download** reports a Foundation `Progress` through `progressHandler:`. It has
  `fractionCompleted`, and for a nicer UI, `localizedDescription` /
  `localizedAdditionalDescription` (which give you "2.1 GB of 4.3 GB" style strings for free —
  used by `mlx-swift-examples`' `DownloadProgressView`, ✅ VERIFIED via the research note).
- **Load** — reading safetensors, quantising, building modules — reports **nothing**. There is no
  progress callback on `_load`.

So a naive `ProgressView(value: loader.progress, total: 1)` sits at 1.0 for several seconds at the
end, which reads as a hang. Two options:

**Option A — a two-phase enum**, which is what you should do:

```swift prelude:guide-context
@MainActor @Observable
final class ModelLoadState {
    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading               // indeterminate
        case ready
        case failed(String)
    }
    var phase: Phase = .idle
}

// in the view
switch state.phase {
case .idle:                 Color.clear
case .downloading(let f):   ProgressView("Downloading model", value: f, total: 1)
case .loading:              ProgressView("Preparing model")      // indeterminate spinner
case .ready:                ChatBody(...)
case .failed(let message):  Text("Could not load model: \(message)")
}
```

Flip to `.loading` when `fractionCompleted` reaches 1.0, and to `.ready` when `loadContainer`
returns.

**Option B — fake checkpoints.** A shipping app broadcasts synthetic progress at load milestones,
clamped to `[0, 0.97]` so the bar never claims completion it cannot verify — community-measured,
from the [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md), which records
`.mlxModelLoadProgress` notifications at 0.12 → 0.3 → 0.55 → 0.95.
Cruder, but it keeps a single bar moving. The clamp is the good idea: **never let a progress bar
reach 1.0 before the thing is actually usable.**

Remember the no-op tokenizer progress handler from §3.2: if your model has a separate
`tokenizerSource`, there is a *third*, unreported download phase. Indeterminate is the honest UI.

### 8.6 A small SwiftUI patterns table

Drawn from the `mlx-swift-examples` research note's cross-cutting catalogue; all ✅ VERIFIED against
that repo at HEAD `378f244`.

| Pattern | Where | One-liner |
|---|---|---|
| Idempotent async load with a stored `Task` | `LLMBasic/ChatModel.swift` | `case .loading(Task<T, Error>)` → concurrent callers `await task.value` |
| Model cache | `MLXService` | `NSCache<NSString, ModelContainer>` |
| Streaming into `@Observable` | all chat apps | `for try await chunk in stream { message.content += chunk }` on `@MainActor` |
| Throttled UI updates | `LoRAEvaluator.evaluateInner` | `if count % evaluateShowEvery == 0 { self.output = output }` |
| Cancellation | `ChatViewModel.generate()` | `withTaskCancellationHandler { try await generateTask?.value } onCancel: { … }` |
| Cancel on disappear | `LLMBasic/ContentView` | `.onDisappear { session?.cancel() }` |
| Auto-scroll while streaming | `ConversationView` | `.defaultScrollAnchor(.bottom, for: .sizeChanges)` |
| Markdown for free | `MessageView` | `Text(LocalizedStringKey(message.content))` |
| Adaptive iPhone layout | `HeaderView`, `MetricsView` | `@Environment(\.horizontalSizeClass)` + `DisclosureGroup` when `.compact` |
| GPU work off the main actor | `Numerical/*/Renderer` | `Task.detached { … await MainActor.run { … } }` |
| Frame-drop guard | `Renderer.tick()` | `guard renderTask == nil else { return }` |
| Timing MLX correctly | `HeatTransfer/Renderer.render()` | call `eval(...)` **inside** the timed region |

That last row is worth its own sentence: **MLX is lazy, so a benchmark that does not `eval` inside
the timed region measures graph construction, not computation.** It is the single most common way
people produce impossible tok/s numbers.

The markdown row deserves a caveat, which Apple's own README supplies (✅ VERIFIED,
`MLXChatExample/README.md:84-96`): `Text(LocalizedStringKey(...))` gives you basic markdown with zero
dependencies but *"does not support advanced features like tables and task lists that are available
in GitHub Flavored Markdown (GFM)"*, and they avoided `swift-markdown-ui` because of an *"unresolved
issue with text selection."*


---

## 9. SDK compatibility: macOS 26 and 27 in one build

### 9.1 The gate

One expression decides whether `MLXFoundationModels` exists in your binary. ✅ VERIFIED — it appears
in **68 files** across `Libraries/`, `IntegrationTesting/` and `Tests/`, counted by grep this
session:

```swift illustrative
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```

Two conditions, doing two different jobs:

- **`FoundationModelsIntegration`** is the SwiftPM trait (§2.3). Default-on; essentially always true.
- **`canImport(FoundationModels, _version: 2)`** is the **SDK version check**. True only on the
  macOS / iOS / visionOS **27.0 SDK**. On the 26 SDK the whole adapter compiles out to an empty
  library.

Separately, all public FM API carries `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)` — the
*runtime* check, which is a different thing from the *compile-time* check.

`Package.swift` states the design intent (✅ VERIFIED, `Package.swift:243-249`, verbatim):

> Public surface is gated by @available(macOS 27 / iOS 27 / visionOS 27, *) and
> #if canImport(FoundationModels), so the target builds on every Xcode that compiles the rest of
> mlx-swift-lm.

⚠️ **SILENT FAILURE — `@available` is not enough, and this is the mistake everyone makes.** If you
guard your own call sites with `if #available(macOS 27.0, *)` alone and build on the **26 SDK**, the
symbols you are calling **do not exist at compile time** — the target compiled to an empty library.
You do not get a clean "requires macOS 27" diagnostic; you get "cannot find `MLXLanguageModel` in
scope", which reads like a missing import or a broken package resolution. **Consumers must mirror
the `#if canImport(FoundationModels, _version: 2)` guard at their own call sites, not just
`@available`.**

The correct shape:

```swift illustrative
#if canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels
#endif

import MLXHuggingFace
import MLXLLM
import MLXLMCommon

enum Backend {
    /// Returns an MLX-backed FoundationModels session when both the SDK and the OS allow it.
    static func makeSession() async throws -> Any? {
        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = #huggingFaceLanguageModel(
                configuration: LLMRegistry.gemma3_1B_qat_4bit,
                capabilities: [.guidedGeneration])
            return LanguageModelSession(model: model)
        }
        #endif
        return nil
    }
}
```

Both layers, every time. The `#if` decides whether the code *compiles*; the `#available` decides
whether it *runs*.

### 9.2 The commit that made CI build on both SDKs

HEAD of the repo at the time of writing is exactly this fix. ✅ VERIFIED, `git show 3cbf928`,
message verbatim:

> The nightly IntegrationTesting job failed to compile on the Xcode 26.5 runner: the FoundationModels
> adapter (MLXFoundationModels) is gated behind `canImport(FoundationModels, _version: 2)` (macOS 27
> SDK only), but the integration test files gated only on the always-set FoundationModelsIntegration
> trait, so they referenced symbols absent on the 26 SDK.
>
> - Extend the 37 FoundationModels-gated test files' top-level guard to
>   `'#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)'`, mirroring the
>   library so they compile out on the 26 SDK and stay active on 27.
> - Workflow: prefer Xcode 27 (via DEVELOPER_DIR) when the runner has it so the full suite runs;
>   otherwise fall back to the default toolchain and run the SDK-agnostic suites (MTP, Qwen3VL/Qwen3.5
>   vision, Coherence, Gemma4, tool calls).

**Read that first paragraph as a warning about your own code.** Apple's own test files made exactly
the mistake described in §9.1 — gating on the trait alone, which is always set — and it went
undetected until a CI runner without Xcode 27 tried to build them. If it can happen in the repo that
defines the gate, it will happen in yours.

The toolchain-selection shell is short enough to copy into your own CI (✅ VERIFIED,
`.github/workflows/integration_tests.yml:21-42`):

```bash
dev=""
for app in /Applications/Xcode_27*.app /Applications/Xcode-27*.app /Applications/Xcode.app; do
  [ -d "$app" ] || continue
  v=$("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | head -1)
  case "$v" in "Xcode 27"*) dev="$app/Contents/Developer" ;; esac
  [ -n "$dev" ] && break
done
if [ -n "$dev" ]; then
  echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"
else
  echo "FoundationModels tests will be compiled out (macOS 27 SDK required)."
fi
```

The split is explicit and worth reproducing in your own test plan:

- **SDK-agnostic suites** (run on Xcode 26): MTP, Qwen3VL / Qwen3.5 vision, Coherence, Gemma4,
  tool calls.
- **27-only suites**: everything under `IntegrationTestingTests/MLXFoundationModelsIntegration/`
  plus `VisionIntegrationTests.swift`.

The docs script does the same thing at a different layer: `scripts/verify-docs.sh` discovers library
products via `swift package dump-package` and **filters out `MLXFoundationModels`**, with the reason
in a comment — *"gated on the FoundationModels v2 SDK, so its DocC catalog can't be verified on SDKs
that lack it."* ✅ VERIFIED. Consistent with `.spi.yml`, which lists only
`[MLXLLM, MLXVLM, MLXLMCommon, MLXEmbedders]` as documentation targets — **`MLXFoundationModels` and
`MLXGuidedGeneration` have no published DocC.** If you go looking for their documentation on Swift
Package Index and find nothing, that is why; read `Libraries/MLXFoundationModels/README.md` instead.

### 9.3 The 27 beta SDK churns, and one of the drifts is a SIGSEGV

Building against a beta SDK means the SDK moves under you. Three documented instances, all
✅ VERIFIED from `mlx-swift-lm` commit messages, with corroborating detail from the community
issue-mining pass:

**1. Enum cases renamed.** Commit `2a76e56`: *"FoundationModels renamed
`GenerationOptions.SamplingMode.Kind`'s `.top`/`.nucleus` cases to
`.randomTopK`/`.randomProbabilityThreshold`, which broke compilation against the newer SDK."* The
community note adds that PR **#431** tracks the current names and warns: *"This churns between Xcode
27 betas; expect local 2-line renames."*

**2. A general API drift pass.** Commit `9cd1a48`, *"Fix FoundationModels API drift and the
integration tests that no longer compiled."* PR **#438**'s description is the more informative
version (community-sourced, verbatim):

> The current FoundationModels SDK (macOS, iOS, and visionOS 27) changed its generation API. … The
> values the framework uses to stream a response (generated text, tool calls, usage, and metadata)
> **became opaque**. Code that receives them can see that something was produced but can no longer
> read what it was.

with the practical consequence that the opaque events *"must still be drained so that sending into
the framework does not stall."*

**3. ⚠️ SILENT FAILURE, escalating to a process abort: an interface/dylib mismatch.** Commit
`1c86cc1`. ✅ VERIFIED from the commit message; the fuller account is community-sourced from PR
**#439** (MERGED 2026-07-17). The FM-27 beta `.swiftinterface` declares

```
LanguageModelExecutorGenerationChannel.Response.Action.updateUsage(input:output:metadata: = [:])
```

but the **shipping FoundationModels dylib exports only** the older two-parameter
`updateUsage(input:output:)`. Calling the two-argument form and relying on the `metadata:` default
resolves to the three-parameter symbol, which does not exist at runtime → dyld cannot bind →
`KERN_INVALID_ADDRESS at 0x0` on every `respond()`. The killer detail, verbatim:

> A runtime dlsym/availability guard cannot help here: under chained-fixups linking (the arm64
> default) the compiled reference alone aborts the process at load, before any guard executes. Not
> referencing the symbol is the only safe option.

The fix was to delete the call entirely. Confirmed with `dyld_info -exports`.

**The transferable lesson:** on a beta SDK, `@available` guards protect you from *OS* version
mismatches, not from *SDK-versus-dylib* mismatches. If a symbol exists in the interface but not in
the shipped library, no runtime guard saves you — the reference itself is fatal under chained
fixups. When a beta API SIGSEGVs at load with `KERN_INVALID_ADDRESS`, check `dyld_info -exports`
before assuming your code is wrong.

Environment strings recorded in those threads, for reproduction: **macOS 27.0 beta (26A5378n),
Xcode 27 beta**; also **macOS 27.0 build 26A5353q**. Community-sourced.

### 9.4 The two availability floors in one example

The README's Foundation Models quick start puts both floors in eight lines, and this is the shape to
copy. ✅ VERIFIED verbatim, `README.md:104-141`:

```swift prelude:guide-context
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct Recommendation {
    let attraction: String
    let neighborhood: String
    let tip: String
}

if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
    let model = #huggingFaceLanguageModel(
        configuration: LLMRegistry.gemma3_1B_qat_4bit,
        capabilities: [.guidedGeneration])
    let session = LanguageModelSession(model: model)

    let recommendation = try await session.respond(
        to: "Recommend one thing to do in Chicago.",
        generating: Recommendation.self)
    print(recommendation.content)
}
```

**`@Generable` is 26.0. `MLXLanguageModel` and `LanguageModelSession(model:)` are 27.0.** Getting
this backwards produces an availability error that names the wrong version and sends you looking in
the wrong place. Note also that the README's snippet omits the `#if canImport(...)` wrapper because
it is illustrative — add it (§9.1).

### 9.5 The other compile-condition strategy: SDK-keyed build settings

`#if canImport(FoundationModels, _version: 2)` is elegant but it only works when the framework
itself is the version signal. For APIs that are *new in 27 but live in a framework that existed in
26*, there is no `canImport` trick. A shipping app solves this with SDK-keyed build settings.
**Community-measured**, read from the [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md),
`project.pbxproj`:

```
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos27.*]"       = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator27.*]"= "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx27.*]"         = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=xros27.*]"           = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=xrsimulator27.*]"    = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
```

with a header comment in the file that uses it, verbatim:

> NOTE: Private Cloud Compute, multimodal `Attachment`, and extended reasoning are iOS 27 / Xcode 27
> SDK symbols that don't exist in the iOS 26 SDK. `#if NOEMA_ENABLE_XCODE27_APIS` gates them at
> compile time; runtime availability checks still apply where the symbols are used.

That last clause is the discipline again: **compile-time gate *and* runtime `@available`.** The same
app uses `#if canImport(CoreAI)` for Core AI, i.e. the `canImport` style where the framework itself
is new, and a clean user-facing error when it is absent:

```swift illustrative
case .frameworkUnavailable:
    return String(localized: "The Core AI framework is unavailable in this build (requires Xcode 27+).")
```

Pick per API: `canImport(Framework)` when the whole framework is new,
`canImport(Framework, _version: N)` when the framework gained a version, and an SDK-keyed
compilation condition when neither works.

Cross-reference [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md) for the full migration view,
including the error-taxonomy changes on the Foundation Models side.

### 9.6 Testing across both SDKs

The commands, ✅ VERIFIED verbatim from `CONTRIBUTING.md:22-55`:

```bash
# unit tests — note: `swift test` DOES NOT WORK, use xcodebuild
xcodebuild test -scheme mlx-swift-lm-Package -destination 'platform=macOS' -skipPackagePluginValidation

# all integration tests
xcodebuild test \
  -project IntegrationTesting/IntegrationTesting.xcodeproj \
  -scheme IntegrationTesting \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation

# docs
scripts/verify-docs.sh
```

⚠️ **Integration tests must run with `-parallel-testing-enabled NO`** — concurrent xctest workers
race on the shared `~/.cache/huggingface/` directory. ✅ VERIFIED,
`.github/workflows/integration_tests.yml`. This is a general lesson for *your* test suite too: if
two test targets download models concurrently into one cache, you will get intermittent, unreproducible
corruption that looks like a checkpoint problem.

Integration tests are `on: workflow_dispatch` only in the current workflow file, with a header
comment saying they are *"Kept out of the PR path so they never block merges."* ✅ VERIFIED.
(Commit `5fbb130` mentions a nightly schedule; the current file has no `schedule:` trigger —
🔴 GAP on whether nightly runs still happen, resolvable only by looking at the repo's Actions
history.)

The integration harness caches one container per model per run using an actor over
`Task<Container, Error>` (✅ VERIFIED, `Libraries/IntegrationTestHelpers/IntegrationTestHelpers.swift`)
— the same idiom as §4.3's `ModelLoader`. Its default generation parameters are
`GenerateParameters(maxTokens: 200, temperature: 0)`. **`temperature: 0` for tests** is the right
default and is worth adopting: the package's own runtime default is `0.6` (§10, item 12), which makes
any test that asserts on output text flaky.


---

## 10. Failure catalogue and pre-ship checklist

### 10.1 The failures that do not throw

Collected from every section, ordered by how long they take to diagnose. Each is marked with its
evidence class.

1. **Backgrounding during generation aborts the process.** Not an exception — a Metal
   command-buffer error delivered on a completion handler, killing the app. Cancel on
   `scenePhase != .active` and *await* the task. ✅ VERIFIED, source comments in `LLMModel.swift`
   and `Evaluate.swift:1899-1906`. §5.6.
2. **Jetsam gives no signal at all.** `Memory.snapshot()` reports MLX's allocator, not
   `phys_footprint`. A model that loads is not a model that runs — the KV cache and the `L²` prefill
   workspace arrive later. ✅ VERIFIED for the mechanism; the monitoring recipe is
   community-measured. §6.7.
3. **EXIF orientation is dropped and the VLM silently describes a rotated scene.** Normalise pixels
   at the picker. ✅ VERIFIED (Apple's own fix commit `378f244`); the underlying CoreImage semantics
   are a declared 🔴 GAP. §7.4.
4. **A trailing empty `.assistant("")` message closes the chat turn.** `ChatSession` strips it; the
   raw `UserInput` path does not. ✅ VERIFIED, `MLXService.swift`. §7.6.
5. **`Attachment`-free image tool calls and other FM-side no-ops** — out of scope here; see
   [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md).
6. **`decode(tokenIds:)` defaults `skipSpecialTokens: false`**, so `<think>` renders as literal text.
   ✅ VERIFIED, `Tokenizer.swift:23-54`. §3.2.
7. **`generation_config.json`'s `eos_token_id` replaces rather than unions** the set from
   `config.json`. Your hand-added stop token disappears. ✅ VERIFIED,
   `LLMModelFactory.swift:569-669`. §4.6.
8. **`stopStrings == nil` silently falls back to `extraEOSTokens`.** Set it to `[]` explicitly to
   disable. ✅ VERIFIED, `ModelConfiguration.swift`.
9. **`kvScheme` overrides `kvBits`, and unrecognised scheme strings are silently ignored.**
   ✅ VERIFIED, `KVCache.swift`. A typo'd scheme means no quantisation and no warning.
10. **Fused SDPA coverage is head-dim-gated and the fallback is silent** — anything outside the
    supported dims materialises a full score tensor. Community-measured; the routing table came from
    MLX's own source. §7.7.
11. **`maybeQuantizeKVCache` replaces array *elements*, not objects**, so the caller's `[KVCache]`
    keeps stale references and the model loses all context generated after the quantisation
    threshold. Community-reported, `mlx-swift-lm` issue **#312** (still OPEN 2026-08-07; fixed on
    main by PR #453, merged 2026-08-05, but in no release). On 3.31.4 or earlier, verify your output.
12. **`temperature` defaults to `0.6`, not `0`.** ✅ VERIFIED, `Evaluate.swift:54-169`. Any test that
    asserts on generated text is flaky until you pass `temperature: 0`. And **`seed` is inert at
    `temperature == 0`** — setting a seed to "make it deterministic" while temperature is already 0
    does nothing and misleads the next reader.
13. **`RotatingKVCache` becomes untrimmable once its window wraps**, silently breaking speculative
    rollback and prompt-cache prefix reuse. Community-reported, issue **#424**. Gemma-family sliding
    windows are small enough (e.g. 512) that one long reply is enough.
14. **`ModelRegistry` is a deprecated typealias in *both* `MLXLLM` and `MLXVLM`** — ambiguous if you
    import both. ✅ VERIFIED. Write `LLMRegistry` / `VLMRegistry`.
15. **`MTPDrafterTypeRegistry.shared` is empty at bootstrap.** You must
    `await Gemma4AssistantRegistration.register()` before loading a Gemma 4 drafter — otherwise the
    MTP iterator **silently falls back to single-token passthrough: no error, just no speedup.**
    ✅ VERIFIED for the registration requirement (`Libraries/MLXVLM/Gemma4AssistantRegistration.swift`);
    the silent-passthrough detail is community-sourced from PR #415.
16. **The shipped agent skill and the per-library READMEs reference packages that do not exist**
    (`swift-huggingface-mlx`, `swift-tokenizers-mlx`, modules `MLXLMHuggingFace`, `MLXLMTokenizers`,
    `MLXEmbeddersHuggingFace`). So does `upgrade.md`. ✅ VERIFIED by grep. §2.6, §5.1.

### 10.2 The failures that do throw, and what they mean

| Error | Real cause |
|---|---|
| `ModelFactoryError.noModelFactoryAvailable` | You linked `MLXLMCommon` but not `MLXLLM`/`MLXVLM`. §4.2 |
| `ModelFactoryError.configurationFileError` | No `config.json` in the directory. §4.5 |
| `ModelFactoryError.configurationDecodingError` | `config.json` present but its `model_type` block does not decode |
| A *VLM* error when you loaded an LLM | The registry tries VLM first and keeps only the **last** error. Call the specific factory to see the real one. §4.2 |
| `DirectoryError.unresolvedModelDirectory` | You asked for a directory from a configuration that is still a remote id |
| `VLMError.singleImageAllowed` / `.singleMediaTypeAllowed` | The model takes one image, or refuses mixed media in a turn. §7.2 |
| `TokenizerError.missingChatTemplate` | The tokenizer has no chat template; you must build the prompt yourself |
| "cannot find type `HubClient` in scope" inside a macro expansion | A missing `import` at *your* call site. §3.4 |
| "cannot find `MLXLanguageModel` in scope" | You are building on the 26 SDK. §9.1 |
| `KERN_INVALID_ADDRESS at 0x0` on first `respond()` | SDK interface/dylib symbol mismatch. Check `dyld_info -exports`. §9.3 |
| `Fatal error: SmallVector out of range` | A 1-D `LMInput` handed to a VLM `prepare`. Fixed upstream (PR #435); route through `context.processor.prepare`. Community-sourced |

### 10.3 Pre-ship checklist

**Setup**
- [ ] `mlx-swift-lm` pinned with `.upToNextMajor(from: "3.31.3")`, not tracking `main`.
- [ ] You chose an integration style deliberately (§3.5) and, if you download at runtime on iOS, you
      chose style 1.
- [ ] `MLXLLM` and/or `MLXVLM` are **linked**, not just `MLXLMCommon`.
- [ ] `-skipMacroValidation` in any `xcodebuild` invocation, if you use the macros.
- [ ] All six imports present at every macro call site.

**Loading**
- [ ] Model weights land somewhere non-purgeable on iOS — not bare `Library/Caches`.
- [ ] Downloaded files validated (`isGitLFSPointer`, safetensors magic, SHA) before first load.
- [ ] Concurrent load requests share one `Task`, not one download each.
- [ ] Paths re-resolved on launch rather than trusted from a previous install.

**Concurrency**
- [ ] One `ChatSession` per conversation; never shared across tasks.
- [ ] `eval()` before any `MLXArray` crosses an isolation boundary.
- [ ] `…Task` variants used wherever a consumer can stop early, with `await task.value`.

**Memory**
- [ ] `com.apple.developer.kernel.increased-memory-limit` entitlement present.
- [ ] `Memory.cacheLimit` set deliberately and re-asserted after library loads.
- [ ] Fit test covers weights **+ KV + prefill workspace**, re-run on context change.
- [ ] `phys_footprint` / `os_proc_available_memory` monitored with a hysteretic ladder.
- [ ] Generation cancelled and awaited on background; large models unloaded with re-evaluation.
- [ ] Wired-memory ticket sized from `WiredMemoryUtils.tune`, `kind:` passed explicitly.

**Media**
- [ ] Image orientation normalised at the picker, before MLX sees the file.
- [ ] Explicit `Transferable` wrappers for PhotosPicker; files copied out of `receivedFile.file`.
- [ ] Security-scoped resources started and stopped on macOS.
- [ ] `Processing.resize` set intentionally — you know it defaults to 512×512 in `ChatSession`.
- [ ] Trailing empty assistant message trimmed on the raw `UserInput` path.

**SDK**
- [ ] Every `MLXFoundationModels` call site wrapped in **both**
      `#if canImport(FoundationModels, _version: 2)` and `if #available(… 27.0, *)`.
- [ ] CI builds on the SDK you actually ship against, and ideally on both.
- [ ] Integration tests run with `-parallel-testing-enabled NO`.
- [ ] `temperature: 0` in any test that asserts on output.

### 10.4 Where to go next

- **Porting a model architecture** — `Libraries/MLXLMCommon/Documentation.docc/porting.md` (777
  lines) plus `skills/mlx-swift-lm/references/model-porting.md`. The canonical attention body,
  `@ModuleInfo` / `@ParameterInfo` conventions, `sanitize(weights:)`, and the trace-and-compare
  debugging recipe against Python.
- **KV cache and generation tuning** — this part's cache guide; `Documentation.docc/kv-cache-quantization.md`
  is the authoritative scheme table.
- **The FoundationModels bridge** — [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).
- **Shipping, updating and operating** — [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md).
- **Migrating an iOS 26 app** — [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md).
- **The Python side** — [Part 12](../../part-12-mlx-python/README.md), with the caution that the Swift port
  has different bugs.

---

## 11. Sources

### Primary — read from the working tree this session

`ml-explore/mlx-swift-lm` at HEAD `3cbf928b5eb24190e8952725699ae6a3bb02824d`
(*"Integration tests: build on both macOS 26 and 27 SDKs (#464)"*, 2026-07-24, Charlie Le
\<charlie_le@apple.com\>), MIT licensed:

- `README.md`, `CONTRIBUTING.md`, `Package.swift`, `.swift-format`, `.spi.yml`
- `.github/workflows/pull_request.yml`, `.github/workflows/integration_tests.yml`
- `Libraries/MLXLMCommon/`: `ModelContainer.swift`, `ModelFactory.swift`, `Downloader.swift`,
  `Tokenizer.swift`, `TokenizerLoader.swift`, `UserInput.swift`, `ModelConfiguration.swift`,
  `LanguageModel.swift`, `Evaluate.swift`, `ChatSession.swift`, `KVCache.swift`, `Load.swift`,
  `BaseConfiguration.swift`, `WiredMemoryPolicies.swift`, `WiredMemoryUtils.swift`,
  `SpeculativeDecoding.swift`, `Utilities/SerialAccessContainer.swift`,
  `Registries/ModelTypeRegistry.swift`
- `Libraries/MLXLMCommon/Documentation.docc/`: `using.md`, `upgrade.md`, `wired-memory.md`,
  `porting.md`, `developing.md`, `kv-cache-quantization.md`
- `Libraries/MLXLLM/`: `LLMModelFactory.swift`, `LLMModel.swift`,
  `Documentation.docc/using-model.md`
- `Libraries/MLXVLM/`: `VLMModelFactory.swift`, `MediaProcessing.swift`,
  `Gemma4AssistantRegistration.swift`
- `Libraries/MLXHuggingFace/`: `Macros.swift`, `FoundationModelsMacros.swift`
- `Libraries/MLXFoundationModels/MLXLanguageModel.swift`
- `Libraries/MLXCXGrammar/xgrammar/VERSION`
- `skills/README.md`, `skills/mlx-swift-lm/SKILL.md`,
  `skills/mlx-swift-lm/references/{concurrency,wired-memory,model-container,generation}.md`
- `scripts/verify-docs.sh`

### Research notes read this session

- `notes/repos/mlx-swift-lm.md` — 2,751 lines; the full deep dive behind §2–§7.
- `notes/repos/mlx-swift-examples.md` — 3,348 lines; `ml-explore/mlx-swift-examples` at HEAD
  `378f244` (*"MLXChatExample: fix VLM image handling on iOS (PhotosPicker, EXIF, empty assistant
  trim) (#472)"*, 2026-06-16). Source of every sample-app listing in §4, §6, §7 and §8.
- [`notes/repos/noema-ios.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) — 2,225 lines; frozen Noema 3.5 snapshot, a shipping
  third-party iOS app. **All material from this source is labelled community-measured in the text.**
  Source of §6.7–§6.9, §8.2's isolation pattern, §9.5's SDK-keyed conditions.
- `notes/repos/issues-mlx-stack.md` — 1,183 lines; a GitHub issue/PR mining pass over `mlx`,
  `mlx-lm`, `mlx-swift-lm` and `mlx-swift-examples`. **Community-sourced throughout**; source of
  §7.7's VLM memory numbers, §9.3's SDK-drift accounts, and several entries in §10.1.
- `notes/repos/swift-lm.md` — 3,079 lines; `1amageek/swift-lm`, a *different* project (a Core AI
  export toolchain, not an MLX package). Consulted and found not to bear on this guide beyond
  confirming the name collision. If you search for "swift-lm" expecting `mlx-swift-lm`, note that
  `1amageek/swift-lm` is unrelated — and that issue numbers cited as "swift-lm#NNN" in the mining
  note refer to `ml-explore/mlx-swift-lm`.
- `notes/repos/coreai-models-nonllm.md` — consulted for the cross-stack EXIF finding in §7.4, where
  it **conflicts** with the `mlx-swift-examples` evidence. The conflict is reported, not resolved.
- `notes/CORRECTIONS-PENDING.md` — reviewed; no entry names Part 13.

### Declared gaps

| § | Gap | What would resolve it | Safe default |
|---|---|---|---|
| 3.3 | No integration package appears to exist despite `using.md` naming one | A released package vending `loadContainer(from: HubClient, configuration:)` | Use style 1 or 3 |
| 4.3 | `useLatest:` semantics undocumented | The `Downloader` protocol's DocC, or `HubClient.downloadSnapshot` | Leave it `false` |
| 6.2 | Whether `GPU.set(cacheLimit:)` survives as a deprecated alias in mlx-swift 0.31.x | `Source/MLX/{GPU,Memory}.swift` in `ml-explore/mlx-swift` at your resolved tag | Write `Memory.cacheLimit` |
| 6.5 | Whether `ticket(size:kind:)`'s `kind:` has a default | `WiredMemoryTicket` in `mlx-swift` | Always pass `kind:` |
| 7.4 | Whether `CIImage(contentsOf:)` applies EXIF orientation | A five-line test on the OS you ship | Normalise pixels yourself |
| 8.2 | Exact `swift-async-algorithms` `throttle(for:reducing:)` spelling | That package's public interface | Manual accumulation |
| 9.6 | Whether the integration workflow still runs nightly | The repo's Actions history | Assume manual only |

### On numbers in this guide

Every figure is attributed at its point of use. To summarise the classes:

- **Apple-published, hardware unstated:** the two weight-measurement rows in §6.4, from
  `MLXLMCommon`'s own `wired-memory.md`. The article says "local measurements" and names no machine
  or OS build.
- **Apple-published, from sample source:** every `cacheLimit` / `memoryLimit` value in §6.3 — these
  are constants in shipping sample code, not benchmarks.
- **Community-measured, hardware named:** §7.7's VLM prefill table (48 GB M4 Pro, from
  `mlx-swift-lm` PR #455, merged 2026-07-22).
- **Community-measured, hardware unstated:** the device RAM table and pressure thresholds in
  §6.7–§6.8, read from a shipping third-party app's source. These are that app's *policy constants*,
  not measurements of MLX.
- **Nothing in this guide was measured by us.** No benchmark in this document was run for it.

---

*Part 13 · Reference 01. Written 2026-07-28 against `mlx-swift-lm` HEAD `3cbf928` (2026-07-24) and
`mlx-swift-examples` HEAD `378f244` (2026-06-16). Both repositories move quickly: re-check
`README.md`, `upgrade.md` and `Package.swift` before treating any signature here as current.*
