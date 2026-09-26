# Part 13 — MLX in Swift

**Version floor:** `mlx-swift-lm` **3.x** — pin `.upToNextMajor(from: "3.31.3")`; latest release
**3.31.4** (2026-06-30). The package declares `swift-tools-version: 6.1` and platforms **macOS 14 /
iOS 17 / tvOS 17 / visionOS 1** — low floors, and not the ones that bite. The floors that bite are
three different numbers: **`MLXFoundationModels` requires the macOS / iOS / visionOS 27.0 SDK** to
compile at all (on the 26 SDK the whole target compiles to an **empty library**);
**`MLXGuidedGeneration` has no 27 floor** and runs on iOS 17 / macOS 14; and **`@Generable`, the
Foundation Models macro, is 26.0**. Xcode 26 is enough for everything except the bridge. Apple
silicon, on a device — the simulator measures nothing.

**Who this is for:** Swift app developers taking a Hugging Face checkpoint from "it runs on my Mac"
to "it survives an iPhone." Choosing MLX over Core AI or `SystemLanguageModel` is
[Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md); the Python side is [Part 12](../part-12-mlx-python/README.md) —
and note the Swift port has *different* bugs, several of them worse.

> ⚠️ **READ THIS BEFORE YOU ADD THE DEPENDENCY.** `main` is a **new major version, 3.x**, and it
> broke the API. Apple's own README says so: *"In order to decouple from tokenizer and downloader
> packages some breaking changes were introduced."* Download and tokenization are now **protocols
> you supply a conformance for** — the package has exactly two dependencies, `mlx-swift` and
> `swift-syntax`, and no Hugging Face dependency at all. Every tutorial, blog post and coding-agent
> memory written before roughly April 2026 describes the 2.x API (`loadModelContainer(hub:configuration:)`,
> `HubApi`, `perform { model, tokenizer in }`) and **none of it compiles against 3.x**. Pin a
> version; do not track `main`.

---

## Why this part exists

Four things make MLX-in-Swift harder than "add a package and call `generate`."

1. **The package changed shape under everyone.** The libraries first *moved repositories* — out of
   `mlx-swift-examples` into `ml-explore/mlx-swift-lm` — and then went 3.x. The upgrade document
   that explains it is famously 404'd (issue **#217** is literally titled *"3.31.3 release's upgrade
   notes are 404'd"*); the README anticipates this and tells you to read the source instead. Several
   shipped per-library READMEs and the repo's own `skills/` directory still reference modules that
   **do not exist** (`MLXLMHuggingFace`, `MLXLMTokenizers`, `MLXEmbeddersHuggingFace`).
2. **`MLXFoundationModels` is not a framework, and people cannot find it.** It is a library *target*
   inside the package, gated by `#if canImport(FoundationModels, _version: 2)` — because the
   FoundationModels module ships in **both** SDKs (1.4.x on 26, 2.0.x on 27), so
   `canImport(FoundationModels)` is true on 26 and tells you nothing. `@available` cannot save you:
   it gates *runtime* availability, not the *compile-time* presence of a symbol.
3. **MLX is the backend where nothing hides the logits.** Grammar-constrained decoding needs
   per-step logits; Core AI's fastest engine samples on-GPU and never surfaces them, so `@Generable`
   and the fast path are mutually exclusive there. On MLX there is no such fork — `model(input,
   cache:)` returns an `MLXArray` and the mask is added to it.
4. **Almost nothing throws.** Across these three guides there are roughly **thirty** documented
   non-throwing failure modes, plus the one with no signal at all: on iOS, exceeding your memory
   limit does not warn, does not run your `deinit`, and does not throw — the kernel kills you.

---

## Read this first: the triage table

| If your situation is… | Read | Why |
|---|---|---|
| "The sample code I found doesn't compile" | [13.1 §1, §2.6](references/01-mlx-swift-lm-in-an-app.md#1-the-3x-version-warning-in-full) | It is 2.x. The migration table is there |
| "First build fails and I don't know which products to link" | [13.1 §2–§3](references/01-mlx-swift-lm-in-an-app.md#2-the-package-nine-products-what-each-is-for) | Nine products, **three integration styles**; §3.5 decides for you |
| `ModelFactoryError.noModelFactoryAvailable` | [13.1 §4.2](references/01-mlx-swift-lm-in-an-app.md#42-the-factory-registry-and-the-error-you-will-hit-first) · [13.3 §3.3](references/03-fm-bridge-and-guided-generation.md#33-️-silent-failure-almost-nomodelfactoryavailable) | You linked `MLXLMCommon` but not `MLXLLM`/`MLXVLM`; the registry uses `NSClassFromString` |
| "cannot find `MLXLanguageModel` in scope" | [13.3 §1](references/03-fm-bridge-and-guided-generation.md#1--the-two-gates-and-the-four-cell-matrix) · [13.1 §9.1](references/01-mlx-swift-lm-in-an-app.md#91-the-gate) | You are on the 26 SDK. The target compiled to an empty library |
| "It is killed on device with no crash report" | [13.1 §6.7–§6.8](references/01-mlx-swift-lm-in-an-app.md#67-what-jetsam-looks-like-and-how-to-see-it-coming) | Jetsam. `Memory.snapshot()` reports MLX's allocator, not `phys_footprint` |
| "It crashes when the app backgrounds mid-generation" | [13.1 §5.6](references/01-mlx-swift-lm-in-an-app.md#56-cancellation--and-the-ios-crash-it-prevents) | A Metal command-buffer error on a completion handler Swift cannot catch |
| "The VLM describes a rotated scene" · "VLM prefill OOMs" | [13.1 §7.4, §7.7](references/01-mlx-swift-lm-in-an-app.md#74-️-exif-orientation--the-bug-apple-fixed-in-their-own-sample) | EXIF orientation; merged-sequence attention growing as (Σ Lᵢ)² |
| "My 'waiting for first token' spinner never stops" | [13.2 §2.5](references/02-generation-tools-and-caching.md#25-the-stream-event-types) | The first stream element can be `.toolCall` with **zero** `.chunk` events |
| "The model recites a function call at the user" | [13.2 §7.5](references/02-generation-tools-and-caching.md#75-detection-toolcallformatinfer-rule-by-rule) | `ToolCallFormat.infer` returned `nil`, the loop assumed `.json` |
| "Output is fluent but subtly worse than it should be" | [13.2 §6.4–§6.5](references/02-generation-tools-and-caching.md#64-️-silent-failure-5--the-chat-template-is-the-contract-and-nothing-checks-it) | The chat template is the contract and nothing checks it |
| "I set `kvBits` and memory didn't drop" · "quality collapses mid-generation" | [13.2 §8.5, §9.1](references/02-generation-tools-and-caching.md#85-quantized-kv-kvbits-kvscheme-and-turboquant) | `RotatingKVCache.toQuantized()` is never called; and `#312` |
| "Speculative decoding gives wrong answers on Gemma" | [13.2 §9.2](references/02-generation-tools-and-caching.md#92-speculativetokeniterator-discards-trimpromptcaches-return-value) | `#424` — generation continues on tokens that were never emitted |
| "Where *is* `MLXFoundationModels`?" | [13.3, opening](references/03-fm-bridge-and-guided-generation.md) | Answered in the first paragraph, because forum thread 836264 asked |
| "`session.prewarm()` does nothing" · "usage is zero" | [13.3 §7.6, §8.8](references/03-fm-bridge-and-guided-generation.md#76-️-silent-failure-the-prewarm-witness-must-match-exactly) | A witness that didn't bind; and a deliberately-dropped channel send |
| "I want `@Generable`-style JSON on iOS 17" | [13.3 §9](references/03-fm-bridge-and-guided-generation.md#9--mlxguidedgeneration-from-json-schema-to-token-mask) | `MLXGuidedGeneration` is standalone — no Foundation Models, no 27 floor |

---

## The guides in this part

### [13.1 — `mlx-swift-lm` in an app: setup, concurrency, memory, and media input](references/01-mlx-swift-lm-in-an-app.md)

The "make it survive contact with an iPhone" guide, in the order things hurt: the 3.x break and the
nine products; the **three integration styles** for tokenizers and downloaders (implement the
protocols, use an integration package, or use the `MLXHuggingFace` macros) with a decision in §3.5;
`ModelContainer`/`ModelContext`, download progress and exactly where weights land; concurrency —
why `ModelContainer` is *not* an actor, why `MLXArray` is not `Sendable`, what `SendableBox` is for;
**memory**, the longest section and the one that decides whether you ship; VLM media input; and
building against both the 26 and 27 SDKs. §10 is a failure catalogue plus a pre-ship checklist.

> ⚠️ **SILENT FAILURE — jetsam, the loudest one, because there is no signal at all.** Exceeding the
> process memory limit on iOS does not throw, does not reliably call
> `applicationDidReceiveMemoryWarning`, and does not run your `deinit`. You get *"Terminated due to
> memory issue"* in Xcode and a one-star review saying "it just closes." `Memory.snapshot()` will
> not save you — it measures MLX's allocator, not the footprint the kernel measures. Also here:
> **backgrounding during generation aborts the process** (a Metal command-buffer error on a
> completion handler; cancel on `scenePhase` *and await the task*); **`decode(tokenIds:)` defaults
> `skipSpecialTokens: false`**, so `<think>` renders as literal text; **`generation_config.json`'s
> `eos_token_id` replaces rather than unions** the set from `config.json`; and **EXIF orientation is
> dropped**, so the VLM confidently describes a rotated scene.
>
> 🔴 **GAP — the integration package `using.md` names may not exist.** `upgrade.md` shows a call
> shape with no `using:` parameter, importing an `IntegrationPackage` that has no corresponding
> module, dependency, or published overload anywhere we could find. **Safe default: use style 1 or
> style 3; do not design around an integration package existing.** Also open: what `useLatest:`
> actually does (leave it `false`), and whether `GPU.set(cacheLimit:)` survives as a deprecated
> alias — write `Memory.cacheLimit`.

### [13.2 — Generation, tool calling, and KV cache management in Swift](references/02-generation-tools-and-caching.md)

Deliberately structured to mirror [Part 12 guide 04](../part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md)
so you can move between the languages, naming the Python spelling wherever one corresponds — and
calling out every place it doesn't, because each of those divergences has produced a real bug.
`generate` / `generateTokens` / `generateTask` / `ChatSession` and the `TokenIterator` underneath;
`GenerateParameters` field by field; **ten** tool-call wire formats and how the library detects each;
**eight** concrete KV cache types mapped to their Python counterparts; prompt caching to disk; and
`MLXEmbedders` for the local RAG case. §11 collects a nine-entry silent-failure register, a gap
register, and the **four-hop fix chain** (`mlx` → `mlx-c` → `mlx-swift` → `mlx-swift-lm`) that
explains why an upstream fix takes four tag bumps to reach your app.

> ⚠️ **SILENT FAILURE — the chat template is the contract, and nothing checks it (§6.4).** A missing,
> mismatched or partially-honoured template produces **fluent, plausible, degraded output** — not
> gibberish, not an error, just worse instruction-following that gets blamed on the model. Four ways
> it happens, including a system prompt silently discarded by `NoSystemMessageGenerator` and
> `additionalContext` keys Jinja ignores. §6.5 is a ten-second render-and-eyeball recipe. Eight more,
> including: `topP`/`topK`/`minP` are **ignored entirely at `temperature: 0`** (which defaults to
> `0.6`, not `0` — every test asserting on text is flaky until you set it); an unrecognised `kvScheme`
> string is dropped with no message; and `RotatingKVCache.toQuantized()` **exists and is never
> called**, so on sliding-window models `kvBits` converts nothing and memory does not drop.
>
> ⚠️ **Two open bugs that destroy output quality rather than crashing (§9).** `#312` —
> `maybeQuantizeKVCache` replaces array *elements* instead of mutating objects, so the caller keeps
> stale references and **the model loses all context generated after `quantizedKVStart`**. `#424` —
> `SpeculativeTokenIterator` discards `trimPromptCache`'s return value, and once one sliding layer
> wraps the rollback silently returns `0`, so **generation continues on a transcript containing
> tokens that were never emitted**. Both OPEN as of 2026-07-29; treat the status as a snapshot.
>
> 🔴 **GAP — no verified public API for registering a custom `ToolCallParser`.** `ToolCallProcessor.init`
> takes a closed `String`-backed `ToolCallFormat` enum you cannot extend. If your model's wire format
> is not one of the ten, parse it yourself outside the loop (§7.8 remedy d). Also open: cross-language
> prompt-cache round-tripping, and the accept/reject arithmetic inside `SpeculativeTokenIterator`.

### [13.3 — `MLXFoundationModels` and `MLXGuidedGeneration`: backing `LanguageModelSession` with an MLX model](references/03-fm-bridge-and-guided-generation.md)

Opens by answering the question a developer asked on forum thread **836264** after seeing
`import MLXFoundationModels` on a WWDC26 session-339 slide: it is a library target in the package,
not an SDK framework, and it needs the 27.0 SDK. From there it is the most useful thing in the part
even if you never ship an MLX model — **the most readable complete implementation of the
`LanguageModel` / `LanguageModelExecutor` protocol pair that exists**, walked file by file, plus
`MLXGuidedGeneration`'s JSON-Schema-to-token-mask pipeline, its zone-based budget policy, and a
27-beta SDK-drift log that is a case study in surviving a moving SDK. It also documents something in
no Apple material: **Apple's `apple/coreai-models` and `ml-explore/mlx-swift-lm` independently chose
the same third-party library, `mlc-ai/xgrammar`** — proven by a build setting that renames the
vendored C++ namespaces *"so this target's symbols cannot collide with another xgrammar in the same
binary (e.g. CoreAI's prebuilt copy)."*

> ⚠️ **SILENT FAILURE — most of what you would patch in a `ModelConfigurationResolver` is inert
> (§8.3).** The adapter consumes **only `reasoningConfig`** from the resolved value; patching
> `extraEOSTokens`, `eosTokenIds`, `toolCallFormat` or any identity field compiles, runs on every
> request, and changes nothing. Five more: a `prewarm` witness whose signature doesn't match
> *exactly* fails to bind and the framework's no-op default wins; `availability == .available` checks
> **one file** (`config.json`), so a partial download reports Ready and fails at load; tool calls with
> an unrecognised name are `compactMap`ped away with **no error and no log**; `flushLogs()` returns
> `nil` unconditionally, so `diagnosticLog: true` yields nothing; and `emitUsage` computes usage,
> notifies the test observer, and **sends nothing to the framework**.
>
> ⚠️ **The `updateUsage` SIGSEGV is the beta-SDK failure mode to fear (§13.2).** The FM-27
> `.swiftinterface` declares a three-parameter `updateUsage(input:output:metadata:)`; the shipping
> dylib exports only the two-parameter form. Relying on the `metadata:` default mangles a reference to
> a symbol that does not exist, and **under chained fixups (the arm64 default) the compiled reference
> aborts the process at image load, before any `#available` or `dlsym` guard can run.** The only fix
> is to delete the call — which is what they did, at the cost of the missing-usage silent failure
> above. `dyld_info -exports` is how you check.
>
> 🔴 **GAP — every performance number in this guide is an unattributed source comment (G4).** Six of
> them, none carrying hardware, OS build, model or date, and two in open tension (*"grammar
> compilation ~5-20ms"* versus *"hundreds of milliseconds on a cold grammar compile"*). Nine more
> gaps are registered in §14, including whether the constraint-template cache works at all — cloning
> needs xgrammar `Fork()`, documented as unavailable before v0.1.34, and **the vendored copy is
> v0.1.30** — plus Dynamic Profiles on a third-party model, watchOS (don't), and KV reuse across
> turns (assume there is none; the guided path demonstrably re-prefills every request).

---

## Reading order

**Everyone starts at [13.1 §1–§4](references/01-mlx-swift-lm-in-an-app.md#1-the-3x-version-warning-in-full).** The 3.x break, the
product list, the three integration styles and model loading are the vocabulary the other two guides
assume, and getting §3 wrong is the single most common reason a first build fails. Then **§6, in
full, before you write a feature** — memory is what decides whether the app ships, and every number
in it is a device number.

**Then branch by what you are building.** *Driving MLX directly:* go to
[13.2](references/02-generation-tools-and-caching.md) — §2–§4 make it work, §6 makes it correct
(read §6.4 even if you skip everything else), §7 only if you call tools, §8–§9 only when memory or
long conversations become a problem. *Putting an MLX model behind `LanguageModelSession`:* go
straight to [13.3](references/03-fm-bridge-and-guided-generation.md) after 13.1 §1–§4 — §1 (the two
gates), §3 (setup), §6 (capabilities) and §7 (availability) are the ones you cannot skip, and §8's
file-by-file walk doubles as the checklist for
[Part 4 guide 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md).

**Read two out of order.** [13.1 §9](references/01-mlx-swift-lm-in-an-app.md#9-sdk-compatibility-macos-26-and-27-in-one-build) before you configure
CI, because the 26-versus-27 SDK question decides your build matrix and cannot be papered over with
`@available`. And [13.3 §11](references/03-fm-bridge-and-guided-generation.md#11--the-constraint-guided-generation-needs-logits) before you pick a
backend, because "does this engine expose logits" is the question that decides whether `@Generable`
works at all.

**Deferrable.** [13.1 §7](references/01-mlx-swift-lm-in-an-app.md#7-media-input-for-vlms) unless you ship a VLM;
[13.2 §9–§10](references/02-generation-tools-and-caching.md#9-two-real-swift-side-cache-bugs) unless you enable KV quantization,
speculative decoding, or need an embedder in-process; all of
[13.3](references/03-fm-bridge-and-guided-generation.md) if you are on Xcode 26 — except **§9**,
which is `MLXGuidedGeneration` and has no 27 floor at all, so grammar-constrained JSON is available
to you on iOS 17 without Foundation Models anywhere in the picture.

---

## What this part deliberately does not cover

- **Porting a model architecture to Swift.** `@ModuleInfo`/`@ParameterInfo` conventions,
  `sanitize(weights:)`, the canonical attention body, and trace-and-compare debugging against Python
  live in the package's own `Documentation.docc/porting.md` (777 lines) and
  `skills/mlx-swift-lm/references/model-porting.md`. [13.1 §10.4](references/01-mlx-swift-lm-in-an-app.md#104-where-to-go-next)
  points you at both. **LoRA / DoRA on device** (`LoRAContainer`, `LoRATrain`) is likewise out of
  scope here.
- **The `LanguageModel` protocol taught abstractly**, the executor store, and choosing among the five
  conformers: [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md). 13.3 is the concrete companion, not
  the treatment. Everything *in front of* the session — `@Generable`, `Tool`, streaming, the error
  taxonomy — is [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md); context and profiles are
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).
- **The Python side**, including `mlx_lm.server` and the CLI: [Part 12](../part-12-mlx-python/README.md).
  13.2 mirrors its cache guide section for section.
- **Why `head_dim ∈ {72, 96, …}` silently falls back to a composed SDPA**, and what padding costs:
  [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md). 13.2 §9.5 gives only the one-line consequence.
- **Core AI's own guided decoding, engines and bundle format:**
  [Part 7 guide 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md).
  Referenced in 13.3 §10–§11 only for the xgrammar convergence and the logits constraint.
- **Shipping, background delivery and OS-update operations:** [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md).
  **Measuring whether the output is any good:** [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). **Coming from
  `mlx-swift-lm` 2.x:** [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md), whose toolchain guide covers
  the same tokenizer/downloader decoupling from the migration side.

---

## Sources for this part

Strongest first. **Package source read on disk:** `ml-explore/mlx-swift-lm` at HEAD
`3cbf928b5eb24190e8952725699ae6a3bb02824d` — *"Integration tests: build on both macOS 26 and 27 SDKs
(#464)"*, 2026-07-24, authored from an apple.com address — including `Package.swift`, all of
`Libraries/MLXLMCommon` (`Evaluate`, `ChatSession`, `KVCache`, `ModelFactory`, `Downloader`,
`Tokenizer`, `UserInput`, `WiredMemoryPolicies`, the `Tool/` directory), `MLXLLM`, `MLXVLM`,
`MLXEmbedders`, `MLXHuggingFace`, the whole of `MLXFoundationModels` and `MLXGuidedGeneration`, the
vendored `MLXCXGrammar/xgrammar` at `v0.1.30`, the `Documentation.docc` articles (`using`, `upgrade`,
`porting`, `kv-cache-quantization`, `wired-memory`), the shipped `skills/` directory, and the CI
workflows. **Apple's own sample projects:** `ml-explore/mlx-swift-examples` at `378f244` (2026-06-16)
— `LLMBasic`, `MLXChatExample`, `LLMEval`, `llm-tool`, `embedder-tool` — the source of every idiom
shown. **Issue trackers**, a `gh`-CLI pass dated 2026-07-27 across `mlx`, `mlx-lm`, `mlx-swift-lm`
and `mlx-swift-examples`: issues `#217`, `#259`, `#312`, `#406`, `#419`, `#420`, `#424`, `#432`,
`#433`, `#443` and PRs `#334`, `#358`, `#399`, `#415`, `#434`, `#435`, `#438`, `#439`, `#455`, `#456`,
`#464`, with maintainer (`davidkoski`) replies quoted and attributed. **Apple Developer Forums**
threads 836264 (an Apple Engineer/DTS naming PR #334) and 831197. **WWDC26 session 339**, used for
intent and treated as weaker than source everywhere the two disagree. **Community sources, labelled
as such at every point of use and never presented as Apple figures:** `frozen Noema 3.5 snapshot`, a
shipping third-party iOS app, for the memory governor, the `phys_footprint` shim and the pressure
ladder; the cross-repo issue-mining pass for the VLM prefill numbers (48 GB M4 Pro) and the SDK-drift
accounts. **Nothing in this part was benchmarked by us** — every performance figure is attributed to
its source, and 13.3 §14 G4 names the six that carry no attribution at all.
