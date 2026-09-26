# Model bundles, the LLM engines, and grammar-constrained decoding

**Part 7 · Core AI: the Swift runtime · Reference 04**

**Version floor: everything in this guide is 27.0 and only 27.0.** The `apple/coreai-models` Swift
package declares `platforms: [.macOS("27.0"), .iOS("27.0")]` and nothing else — **no visionOS, no
watchOS, no tvOS, no Mac Catalyst product** — at `swift-tools-version: 6.0` with
`swiftLanguageModes: [.v6]` and `cxxLanguageStandard: .cxx17` (✅ VERIFIED, `Package.swift:1`, `:12`,
`:265-266`). The repo README states the
requirement as **"macOS and iOS 27.0+"** and **"Xcode 27.0+"**. The `CoreAI` framework the package
sits on is itself new in the 27 cycle with no 26.x back-deployment, and there is **no Core AI
release-notes page** to diff against — `/documentation/updates/coreai` returns 404. Build with
**Xcode 27** and install the **Metal Toolchain** separately, or a target containing a `.aimodel`
will not compile.

Two floors *inside* that floor matter here:

- **`Float16` does not exist on Intel macOS.** `LogitsScalarType` is `Float16` everywhere except
  `(os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)`, where it degrades to `Float`
  (✅ VERIFIED, `InferenceEngines/InferenceEngine.swift:12-16`). Every logits-handling API in this
  guide changes type under that `#if`. The same guard appears verbatim in the grammar-mask code.
- **The guided-generation path links C++.** `CoreAILanguageModels` carries
  `.define("CXGRAMMAR_IMPORT")` and `linkerSettings: [.linkedLibrary("c++")]` (✅ VERIFIED,
  `Package.swift:57-63`). Adding `CoreAILM` to your app target
  pulls a C++ dependency in whether or not you ever call `@Generable`.

> ⚠️ **Core AI has zero Apple sample-code projects.** Verified this cycle: **0 `sampleCode` entries
> across all 312 indexed Core AI symbols**, and `/documentation/updates/coreai` 404s. Unlike
> Foundation Models, there is no first-party compiling Xcode project to read. The strongest evidence
> available for this guide is the **shipped source of `apple/coreai-models`**, which is on disk and
> was read line-by-line for this guide at commit **`5ed9981` "Move away from deprecated FM API
> (#123)"**, authored **2026-07-23**, on `main`. Every `path:LINE` citation below is against that
> checkout. Where a claim comes from a WWDC transcript instead, it is marked 🟡 RECONSTRUCTED, and
> where nobody has run the thing, this guide says 🔴 GAP rather than guessing.

---

## What this covers

Reference 01 taught you `AIModel` → `InferenceFunction` → `NDArray`. Reference 03 taught you states
and pipelined execution. This guide is the layer **above** all of that: the part where a raw
`.aimodel` becomes something you can ship, and where Apple's own Swift package turns "I have a
converted Qwen3" into `LanguageModelSession(model:)`.

Three things, and they are more coupled than they look:

**The bundle format.** A `.aimodel` alone is not a deployable LLM — it has no tokenizer, no context
length, no vocabulary size, and a diffusion model is seven of them in a trench coat. So Apple's
export recipes emit a **resource folder**: a directory with `metadata.json` at schema version `0.2`,
an `assets` map from role names to filenames, and whatever sidecars the family needs. Apple's
documentation never specifies this format. Its four writers and its two readers are in the repo, and
this guide reconstructs the schema from both ends and reports where they disagree.

**The engines.** `CoreAILanguageModels` ships **three** LLM inference engines plus a VLM engine, and
picks one for you by looking at the *function names inside your model*. The choice is not a tuning
knob — it determines which compute unit you land on, whether you can do multi-turn prefix reuse,
whether you can run an evaluation harness, and whether Apple's flagship structured-output feature
works at all.

**Grammar-constrained decoding.** The genuinely undocumented insight of this whole layer:
`@Generable` on a non-Apple model is implemented by compiling the JSON schema into a **formal
grammar** that **masks the sampler's logits** so an invalid token cannot be emitted. Both Apple's
`coreai-models` and `ml-explore/mlx-swift-lm` independently vendor **`mlc-ai/xgrammar`** to do it,
and there is source-level evidence that the `CoreAI` framework itself ships a third copy. No WWDC
session and no documentation page says any of this.

And the constraint that falls out of the three together, which is the single most consequential
architectural fact in Part 7:

> **Constrained decoding needs per-step logits. The GPU-pipelined engine never exposes them. It is
> also the engine auto-selected for every macOS dynamic export.** So the default fast path and
> `@Generable` are mutually exclusive, and the failure arrives at generation time, not load time.

## What this does *not* cover

- **`coreai-torch`, `torch.export`, and how the `.aimodel` got made.** Part 8.
- **Compression, palettization, quantization recipes and their numerics.** Part 9.
- **Neural-Engine authoring rules** (BC1S layout, `-40000.0` masks, rank ≤ 5). Part 10.
- **Authoring your own `LanguageModel` conformance from scratch.** Part 4 reference 03 does that at
  length, using `ChatCompletionsLanguageModel` and `MLXLanguageModel` as the worked examples;
  `CoreAILanguageModel` is the third conformance and is dissected here only where it differs.
- **Specialization, the model cache and `xcrun coreai-build`.** Part 7 reference 02 — though §2.10
  below covers the one bundle-format consequence of AOT compilation that bites everybody.
- **Non-LLM runtime engines** (`CoreAISegmentation`, `CoreAIObjectDetection`, `CoreAIDiffusion`)
  beyond what their bundle layouts teach about the format. They now have an owning guide in
  [Part 7 reference 05](05-non-llm-engines-bundles-warmup-and-caching.md). `CoreAISpeech` remains in
  [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md).

## What you need

- **Xcode 27** and the 27 SDK. Not a 26 SDK with a 27 deployment target.
- A **clone of `apple/coreai-models`**, because you will read it. It is not on any package index in a
  form you can browse; the Swift Package Index entry documents only four of the five products
  (`.spi.yml` lists `CoreAILM`, `CoreAIDiffusion`, `CoreAISegmentation`, `CoreAIObjectDetection` —
  `CoreAISpeech` is absent).
- An exported bundle. `uv run coreai.llm.export Qwen/Qwen3-0.6B` produces one in a few minutes; the
  `--dry-run` flag tells you what it *would* produce without downloading 1.2 GB of weights.
- Part 7 reference 01 read, or at least skimmed. This guide assumes you know what `AIModel`,
  `InferenceFunction`, `NDArray` and `SpecializationOptions` are.

> **Contribution note before you file anything:** the repo README says, verbatim, *"We are not
> accepting code contributions at this time … If you open a pull request, it will be closed."*
> Issues are open (bug report / model request / workflow feedback templates). Everything in this
> guide that looks like a bug has to be worked around, not patched upstream.

---

## Contents

1. [Why a `.aimodel` is not a model](#1-why-a-aimodel-is-not-a-model)
2. [The bundle format, definitively](#2-the-bundle-format-definitively)
3. [The Swift package: five products, three dependencies](#3-the-swift-package-five-products-three-dependencies)
4. [Loading: `CoreAIRunner`, `PreparedModel`, `ModelResources`](#4-loading-coreairunner-preparedmodel-modelresources)
5. [The engines](#5-the-engines)
6. [KV cache strategy and prefix reuse](#6-kv-cache-strategy-and-prefix-reuse)
7. [Grammar-constrained decoding](#7-grammar-constrained-decoding)
8. [Plugging into Foundation Models](#8-plugging-into-foundation-models)
9. [Bring your own sampling](#9-bring-your-own-sampling)
10. [Quick reference](#10-quick-reference)
11. [Sources and evidence ledger](#11-sources-and-evidence-ledger)

---

## 1. Why a `.aimodel` is not a model

Reference 01 gives you this, and it is genuinely all you need for a small classifier:

```swift prelude:guide-context
import CoreAI

let model = try await AIModel(contentsOf: modelURL)
guard let fn = try model.loadFunction(named: "main") else { return }
var input = NDArray(shape: [1, 3, 224, 224], scalarType: .float32)
// … fill input …
var outputs = try await fn.run(inputs: ["image": input])
let logits = outputs.remove("logits")?.ndArray
```

✅ VERIFIED — this is Apple's own snippet, quoted from the `working-with-coreai` agent skill shipped
in `apple/coreai-models` (`skills/skills/working-with-coreai/SKILL.md`). It is four lines and it
works, because a ResNet is a pure function from pixels to logits.

Now try it with a language model and count what is missing.

- **You have no tokenizer.** The model's inputs are `input_ids: Int32`. Producing those from
  `"Why is the sky blue?"` requires the exact BPE merges, the exact special tokens, and the exact
  Jinja chat template the model was fine-tuned with. None of that is in the graph.
- **You do not know the vocabulary size.** You need it to allocate the logits buffer, and — as §7
  shows — to size a grammar bitmask. `logits.shape` will tell you, but only after a specialization
  you may not want to pay for yet.
- **You do not know the context length.** The KV cache tensors declare a dynamic sequence dimension.
  The number that dimension is *allowed* to grow to lives in the HuggingFace config, not the graph.
- **You do not know when to stop.** Qwen3 declares `eos_token` as `<|im_end|>` (151645) but can also
  emit `<|endoftext|>` (151643); Gemma 3 ends turns with `<end_of_turn>` (106). Those live in
  `tokenizer_config.json`.
- **And for anything that is not a single decoder, you do not have one model.** A VLM is three
  graphs. FLUX.2 is seven. SAM 3's lite export is one asset holding three entrypoints.

So every Core AI export recipe in the repo emits a **directory**, and that directory has a schema.
Apple's WWDC narration calls it "my model bundle" and moves on (326:103-105, 🟡). The README calls it
"a bundle directory containing one or more `.aimodel` plus `tokenizer/` plus `metadata.json`." The
documentation does not specify it anywhere. The next section does.

### 1.1 The three shapes of "more than one model"

Before the schema, the taxonomy — because the bundle format only makes sense once you know which of
these you are looking at. All three ship in `apple/coreai-models`.

| | **A: multi-function** | **B: multi-asset** | **C: multi-bundle** |
|---|---|---|---|
| Files on disk | 1 `.aimodel`, several entrypoints | N `.aimodel` in one directory | N separate bundle dirs |
| Python side | `add_exported_program(entrypoint_name:)` × N, one `to_coreai()` | `save_asset` × N | separate CLI invocations |
| Swift side | `model.loadFunction(named:)` × N | one `AIModel` per component | one `ModelBundle` per model |
| Data between stages | raw `NDArray`, **no copy** | `[Float]` round-trip | your choice |
| Per-stage compression | ✅ | ✅ | ✅ |
| Per-stage **compute unit** | ❌ — one asset, one specialization | ✅ | ✅ |
| Independent load/unload | ❌ | ✅ | ✅ |
| In the repo | SAM 3 lite; **the iOS LLM export** | SD / SD3 / FLUX.2 / **the VLM** | **nothing** |

✅ VERIFIED against `swift/Sources/CoreAIImageSegmenter/ImageSegmentationEngine.swift:871-920`
(pattern A, `detect`'s inputs are the unmodified `NDArray` outputs of the two encoders),
`swift/Sources/CoreAIDiffusionPipeline/Pipelines/PipelineDescriptor+CoreAI.swift:44-137` (pattern B,
one component actor per asset), and the absence of any target in `Package.swift` depending on both
`CoreAILanguageModels` and a vision target (pattern C).

The trade-off worth stating plainly: **multi-function buys zero-copy tensor hand-off and one file;
multi-asset buys independent memory lifetime and per-component compute units.** Diffusion needs the
memory control — a 4 B transformer plus a VAE will not co-reside on a phone — so it pays the copy.
SAM 3 needs the hand-off, so it accepts loading all three graphs at once.

And a fourth reason for pattern A that the WWDC framing understates. Session 325 presents splitting
SAM 3 into `image_encode` / `text_encode` / `detect` as a **latency trick** (run each at a different
cadence). Reading the shipped code shows the split also **selects the Neural Engine preference when
you use `coreai-models.PreparedModel`**—see §4.2. Direct Core AI callers
choose their own options.[^sample-routing-policy]

---

## 2. The bundle format, definitively

There is no published specification. What follows is reconstructed from **four writers** (Python)
and **two readers** (Swift), all read this session, plus the error strings the readers emit — which
turn out to be the best documentation in the repo.

| | Writer | Reader |
|---|---|---|
| LLM | `python/src/coreai_models/export/bundle.py:42-73` | `ModelBundle` + `LanguageBundle` |
| VLM | `python/src/coreai_models/vlm/export.py:361-391` | `ModelBundle` + `LanguageBundle` |
| Diffusion | `python/src/coreai_models/diffusion/pipeline.py:328-347` | `ModelBundle` + `PipelineDescriptor` |
| Segmenter | `python/src/coreai_models/segmentation/pipeline.py:327-339` | `ModelBundle` |

### 2.1 The canonical LLM bundle, byte for byte

This is the entire metadata writer for an LLM export. ✅ VERIFIED, quoted verbatim from
`python/src/coreai_models/export/bundle.py:18` and `:49-70`:

```python
METADATA_VERSION = "0.2"

metadata: dict[str, Any] = {
    "metadata_version": METADATA_VERSION,
    "kind": "llm",
    "name": name,
    "assets": {"main": f"{name}.aimodel"},
    "language": {
        "tokenizer": hf_model_id,
        "vocab_size": getattr(hf_config, "vocab_size", None),
        "max_context_length": getattr(hf_config, "max_position_embeddings", None),
        "embedded_tokenizer": True,
        "function_map": {"main": ["main"]},
    },
    "source": {
        "model_definition": "torch",
        "hf_model_id": hf_model_id,
    },
    "compression": compression if compression != "none" else None,
    "compilation": {
        "date": datetime.now().astimezone().isoformat(),
        "targets": [],
    },
}
```

and the directory it lands in:

```
qwen3_0_6b_4bit_dynamic/
├── metadata.json                       ← the above, json.dump(indent=2)
├── qwen3_0_6b_4bit_dynamic.aimodel/    ← a DIRECTORY (see §2.3)
└── tokenizer/                          ← AutoTokenizer.save_pretrained()
    ├── tokenizer.json
    ├── tokenizer_config.json
    └── …
```

`bundle_llm_asset()` writes the tokenizer with
`AutoTokenizer.from_pretrained(hf_model_id).save_pretrained(bundle_path / "tokenizer")`
(✅ `bundle.py:32`, `:36-39`) and then the metadata. The `.aimodel` itself is written earlier by
`coreai_program.save_asset(...)` in the export pipeline.

Seven top-level keys. Three of them (`source`, `compression`, `compilation`) are **provenance the
Swift readers never look at** — `ModelBundle` decodes only `metadata_version`, `kind`, `name`,
`user_data` and `assets` (✅ `ModelBundle.swift:189-199`). They are there for you and for your build
system. Use them; nothing else will.

### 2.2 The common envelope: `ModelBundle`

Every kind goes through one type. ✅ VERIFIED, `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift:23-35`:

```swift prelude:guide-context
public struct ModelBundle: Sendable {
    public let metadataVersion: String
    public let kind: BundleKind
    public let name: String
    public let bundlePath: URL
    public let userData: [String: String]?

    /// Role-to-filename mapping from the `"assets"` field in metadata.json.
    public let assets: [String: String]

    /// Full metadata.json bytes, preserved so kind-specific decoders can read
    /// their own blocks without re-reading the file.
    public let raw: Data
}
```

That `raw: Data` field is the whole extensibility story, and the doc comment says so
(`ModelBundle.swift:10-15`):

> *"`ModelBundle` parses only the common fields shared across every bundle kind. Kind-specific config
> blocks (`language`, `vlm`, `diffusion`, `segmenter`) are decoded by per-kind types in their
> respective runner modules (`LanguageBundle` in CoreAILanguageModels, etc.) using the preserved
> `raw` JSON."*

So the schema is **open at the top level and closed in the envelope**. If you invent a
`"myapp": {...}` block, `ModelBundle` will happily carry the bytes and your own decoder can pull it
out of `bundle.raw`. There is also a first-class escape hatch that needs no code: `user_data`, typed
`[String: String]?`, decoded from the snake_case key `"user_data"` (✅ `:192`, `:197`). No writer in
the repo emits it. It exists for you.

The rest of the public surface:

```swift illustrative
public enum ComponentKey {
    public static let main = "main"
    public static let vision = "vision"
    public static let embedding = "embedding"
}
public var componentKeys: [String] { assets.keys.sorted() }
public func modelURL(for key: String) -> URL?
public func requireModelURL(for key: String) throws -> URL   // throws .missingField("assets.<key>")
public func verify() throws                                  // stat every declared asset
public init(from path: String) throws                        // tilde-expanded
public init(at url: URL) throws
public init(raw: Data, bundlePath: URL) throws               // designated
```

✅ VERIFIED, `ModelBundle.swift:39-74`, `:116-175`.

Note `init(raw:bundlePath:)`. It takes the metadata **bytes**, not a path. That is the initializer to
use when your bundle arrived through Background Assets, an encrypted container, or a network stream
and you would rather not round-trip it through the filesystem to parse it.

> ⚠️ **`verify()` is never called by `CoreAILanguageModel.init`.** Grep the tree: the only caller is
> the `llm-runner` CLI. Loading a model through the Foundation Models adapter does *not* stat the
> declared assets up front; you find out an asset is missing when the engine tries to open it, with
> a Core AI error rather than the actionable `BundleError.missingAsset` message. **Call `verify()`
> yourself, once, at bundle-install time.** It is a directory walk and it costs nothing.

### 2.3 ⚠️ `.aimodel` and `.aimodelc` are directories

This is the single most load-bearing fact about the format, and it is easy to miss because both look
like file extensions.

**A `.aimodel` is a directory.** Three independent confirmations in the repo:

1. `PreparedModel.resolveCoreAIModelURL(from:)` treats it as a path prefix and looks for siblings
   (`CoreAIShared/Runtime/ModelStructure.swift:111-132`).
2. `estimatedSizeOnDiskBytes` computes it with `URL.recursiveFileSizeInBytes()`, which walks a
   directory tree with `FileManager.enumerator` (✅ `CoreAILanguageModel.swift:163-166`,
   `CoreAIShared/Runtime/FileSize.swift:17`).
3. The Python overwrite path calls `shutil.rmtree(aimodel_path)`.

**A `.aimodelc` is also a directory — and it contains its own, unrelated `metadata.json`.** This is
where it gets genuinely dangerous, and Apple's own reader has a guard for it. ✅ VERIFIED verbatim,
`ModelBundle.swift:121-131`:

```swift illustrative
public init(at url: URL) throws {
    // A model bundle is a *directory* (metadata.json + assets + tokenizer).
    // If the caller points us directly at a `.aimodel`/`.aimodelc` asset,
    // fail with actionable guidance. This must run before any filesystem
    // read: a compiled `.aimodelc` is itself a directory holding its own
    // unrelated metadata.json, which would otherwise parse as a bogus 0.1
    // bundle and surface a misleading "unsupported metadata_version" error.
    let ext = url.pathExtension.lowercased()
    if ext == "aimodel" || ext == "aimodelc" {
        throw BundleError.pointedAtModelAsset(url)
    }
    …
}
```

Read that comment twice. **There are two different `metadata.json` schemas in play**, one owned by
the bundle format documented here and one owned by the Core AI compiler inside a compiled asset. They
share a filename and nothing else. Without the extension guard, pointing a bundle loader at a
`.aimodelc` produces `"unsupported metadata_version '0.1'"` — an error that sends you off to fix your
exporter when the actual problem is that you passed the wrong path.

The error you get instead is the one you want (`ModelBundle.swift:89-92`):

> `'model.aimodelc' is a model asset, not a model bundle directory. A model bundle directory contains
> metadata, a tokenizer, and a model asset.`

**Consequence for your own tooling:** never dispatch on `metadata.json` existing. Dispatch on the
directory's extension first. And if you write a bundle validator, do the `.aimodel`/`.aimodelc`
extension check *before* you read anything, exactly as Apple does.

### 2.4 `assets`: a role → filename map, not a list

```json
"assets": { "main": "qwen3_0_6b.aimodel" }
```

The keys are **roles**, not filenames or indices. The three the Swift side knows by name are
`ComponentKey.main`, `.vision` and `.embedding`, but the map is a plain `[String: String]` and every
kind invents its own vocabulary:

| Kind | Roles emitted by the exporter | Cite |
|---|---|---|
| `llm` | `main` | `bundle.py:53` |
| `vlm` | `main`, `embedding`, then `vision` patched in later | `vlm/export.py:365-368`, `:698` |
| `segmenter` | `main` | `segmentation/pipeline.py:334` |
| `diffusion` | whatever components were exported — `transformer`, `text_encoder`, `text_encoder_2`, `vae_decoder`, `vae_encoder`, `unet`, … | `diffusion/pipeline.py:323-326` |

The VLM writer's comment is worth quoting because it states the contract explicitly
(`vlm/export.py:359-360`): *"Asset roles match Swift `ModelBundle.ComponentKey`: `main` (decoder),
`embedding` (embed.aimodel), `vision` (added by `export_vision_encoder`)."*

Note the "added later": `export_vision_encoder` re-reads `metadata.json`, sets
`metadata["assets"]["vision"] = "vision.aimodel"`, and writes it back (✅ `vlm/export.py:698-702`).
So **a VLM bundle passes through a state where it is a valid `vlm` bundle with no vision asset.**
If your build pipeline copies bundles while an export is running, that is the window.

### 2.5 `metadata_version` must be exactly `"0.2"`

✅ VERIFIED, `ModelBundle.swift:158-161`:

```swift prelude:guide-context
let version = envelope.metadataVersion ?? "0.1"
guard version == "0.2" else {
    throw BundleError.unsupportedVersion(version)
}
```

Three things follow.

1. **A missing key means `"0.1"`, which throws.** There is no lenient mode.
2. **There is no forward compatibility.** `"0.3"` will throw on a 27.0 runtime, and `"0.2"` is
   hard-coded in five places across the Python writers. Anything you build on this schema is pinned
   to one version of one package.
3. **The error text is the version registry**: `"unsupported metadata_version '\(v)' (known: 0.2)"`.
   That string is the only enumeration of known versions anywhere.

Because parsing is two-pass — a `VersionEnvelope` decode, then a `CommonFields` decode
(`ModelBundle.swift:150-175`) — the version check happens **before** any other field is validated. A
0.1-era bundle fails on the version, not on its missing `assets` map, which is the friendlier
failure.

### 2.6 The `language` block, and a discrepancy worth knowing

The LLM-specific config. ✅ VERIFIED, `swift/Sources/CoreAILanguageModels/Bundle/LanguageConfig.swift:11-51`:

```swift prelude:guide-context
/// `language` block of `metadata.json` schema 0.2 — LLM-specific config.
public struct LanguageConfig: Codable, Sendable, Equatable {
    public let tokenizer: String            // "tokenizer"        — an HF model id
    public let vocabSize: Int               // "vocab_size"
    public let maxContextLength: Int        // "max_context_length"
    public let embeddedTokenizer: Bool      // "embedded_tokenizer", defaults to true when absent
    public let functionMap: FunctionMap?    // "function_map"
    public let vision: VisionConfig?        // "vision"
}
```

`tokenizer`, `vocab_size` and `max_context_length` are **required** — decoded with `decode`, not
`decodeIfPresent` (`:55-57`). The other three are optional. `embedded_tokenizer` defaults to `true`
(`:58`).

**`function_map`** is the escape hatch for models whose graph function names do not follow
convention. Its doc comment states the design (`FunctionMap.swift:6-16`):

> *"Most bundles don't need this — the runtime probes `AIModel`'s function list and matches against
> known role names by convention (`main`, `extend_<N>`, `load_embeddings`, etc.). `FunctionMap` is the
> override for bundles whose function names don't follow conventions, or where one logical role maps
> to multiple physical functions."*

```swift illustrative
public struct FunctionMap: Codable, Sendable, Equatable {
    public let entries: [String: [String]]
    public func names(for role: String) -> [String]   // [] if absent
    public func name(for role: String) -> String?     // first, or nil
}
```

Values are **always arrays**, even for a single name, "keeping the JSON shape uniform" — which is why
the LLM writer emits the slightly odd-looking `"function_map": {"main": ["main"]}`. The array form
earns its keep on the iOS chunked-static export, where the role `extend` maps to a dozen physical
functions named `extend_<contextLen>_<queryLen>`.

**`function_map` has exactly one verified consumer, and it only handles the `main` role.**
✅ VERIFIED, `LanguageModel/CoreAIRunner.swift:74`:

```swift prelude:guide-context
let functionName = bundle.language.functionMap?.name(for: "main") ?? "main"
```

That is the whole of it. `name(for:)` takes the **first** element of the array, so the multi-name
capability the type advertises is never exercised on this path.

> 🔴 **GAP — the multi-function roles have no verified consumer.** No bundle in the repo emits a
> `function_map` with anything but `{"main": ["main"]}`, and whether `StaticShapeEngine` consults
> `functionMap` before falling back to its own `extend*` / `prompt*` prefix scan is **unverified** —
> its function categorisation reads `AIModel.functionNames` directly. **Safe default: rename only
> your `main` graph if you must, and otherwise name functions by convention (`main`,
> `extend_<ctx>_<q>`, `prompt_opt_<ctx>_<q>`, `load_embeddings`, `gather_embeddings_<q>`).** Treat a
> multi-name `function_map` as untested. Resolving this needs a chunked-static bundle with
> deliberately non-conventional entrypoint names, run through `llm-runner --verbose` and checked
> against `--verbose-level 2` graph-selection logging.

**And the discrepancy.** `LanguageConfig` declares `vision` as a member of the `language` block. But
the strict LLM/VLM loader decodes `vision` from the **top level** of `metadata.json`
(✅ `LanguageBundle.swift:104-111`):

```swift prelude:guide-context
fileprivate struct LanguagePayload: Decodable {
    let assets: Assets
    let language: LanguageConfig?
    let vision: VisionConfig?          // ← top level, sibling of `language`
    struct Assets: Decodable { let main: String? }
}
```

and the VLM exporter writes it at the top level too, with a comment that says so explicitly
(✅ `vlm/export.py:376-377`): *"Top-level `vision` block consumed by Swift `VisionConfig`
(snake_case keys)."*

So `LanguageConfig.vision` is a **decodable field with no writer**. `LanguageBundle.visionConfig` —
the property the VLM engine actually reads — comes from `payload.vision`, i.e. the top-level block.
Both spellings will decode without error; only one will be seen. **Write `vision` at the top level.**
If you hand-author a bundle and nest it inside `language`, `LanguageBundle(bundle:)` throws
`.missingField("vision")` for a `vlm` kind (`LanguageBundle.swift:51-53`) — with the block sitting
right there in your file.

For completeness, the vision block's own shape (✅ `LanguageConfig.swift`, `VisionConfig`):

| JSON key | Swift | Default |
|---|---|---|
| `image_size` | `imageSize: Int` | required |
| `patch_size` | `patchSize: Int` | required |
| `image_token_count` | `imageTokenCount: Int` | required |
| `image_token_id` | `imageTokenId: Int32` | required |
| `image_mean` | `imageMean: [Double]` | `VisionConfig.clipMean` |
| `image_std` | `imageStd: [Double]` | `VisionConfig.clipStd` |
| `rescale_factor` | `rescaleFactor: Double` | `1.0` |
| `image_strategy` | `imageStrategy: ImageStrategy` | `.stretch` |
| `include_image_info` | `includeImageInfo: Bool` | `false` |

⚠️ The CLIP mean/std defaults are a trap for anything that is not CLIP-derived. Qwen3-VL uses
`(0.5, 0.5, 0.5)` for both, and the repo has a commit fixing exactly that mistake
(`ace0dc6` "Fix Qwen3-VL normalization: use 0.5/0.5/0.5 from checkpoint"). **If you omit
`image_mean`/`image_std` you silently get CLIP's**, and the symptom is degraded captions rather than
an error.

### 2.7 `LanguageBundle`: the strict loader

`ModelBundle` is the lossy peek. `LanguageBundle` is the committed load. ✅ VERIFIED,
`Bundle/LanguageBundle.swift:20-98`:

```swift prelude:guide-context
public struct LanguageBundle: Sendable {
    public let bundle: ModelBundle
    public let modelAssetPath: String
    public let language: LanguageConfig
    public let visionConfig: VisionConfig?

    public init(from path: String) throws          // tilde-expanded
    public init(at url: URL) throws
    public init(bundle: ModelBundle) throws        // upgrade an inspected ModelBundle

    public var name: String { bundle.name }
    public var bundlePath: URL { bundle.bundlePath }
    public var tokenizer: String { language.tokenizer }
    public var vocabSize: Int { language.vocabSize }
    public var maxContextLength: Int { language.maxContextLength }
    public var rawMetadata: Data { bundle.raw }

    public var tokenizerPath: URL?
    public var hasEmbeddedTokenizer: Bool
    public func loadTokenizer() async throws -> any Tokenizer
}
```

The four ways it throws, in the order it checks them (`:35-53`):

1. `kind` is not `.llm` and not `.vlm` → `.kindMismatch(expected: .llm, got: …)`. Note the error says
   `expected: .llm` even when `.vlm` would also have been fine — a cosmetic wart, not a bug.
2. `assets.main` missing → `.missingField("assets.main")`.
3. `language` block missing → `.missingField("language")`.
4. `kind == .vlm` but no top-level `vision` → `.missingField("vision")`.

**Tokenizer resolution is two-tier and quietly network-capable** (✅ `:82-98`):

```swift prelude:guide-context
public var tokenizerPath: URL? {
    guard language.embeddedTokenizer else { return nil }
    let dir = bundlePath.appending(path: "tokenizer")
    let json = dir.appending(path: "tokenizer.json")
    guard FileManager.default.fileExists(atPath: json.path) else { return nil }
    return dir
}

public func loadTokenizer() async throws -> any Tokenizer {
    if let path = tokenizerPath {
        return try await AutoTokenizer.from(modelFolder: path)
    }
    return try await AutoTokenizer.from(pretrained: language.tokenizer)
}
```

> ⚠️ **SILENT FAILURE — a shipped app can try to fetch a tokenizer from the network.** The fallback
> branch calls `AutoTokenizer.from(pretrained:)` with the HuggingFace model id out of
> `metadata.json`. On your Mac that resolves against `~/.cache/huggingface` and succeeds instantly,
> so the missing `tokenizer/` directory never surfaces during development. On a user's device it is
> a HuggingFace Hub request: it needs network, it may be slow, it may 401 on a gated repo
> (`google/gemma-3-*` is gated), and it will fail entirely offline. And notice the trigger: not
> `embedded_tokenizer: false`, but **`tokenizer/tokenizer.json` merely being absent** — a
> `.gitignore` that skips `*.json`, an asset-packaging step that flattens directories, or a
> `--overwrite`-less re-export that skipped the tokenizer save (see §2.11) all produce it.
> **Defence:** assert `bundle.hasEmbeddedTokenizer` at install time, and fail loudly if it is false.
> It is one line and it converts a field failure into a build failure.

### 2.8 The diffusion bundle: three resolution mechanisms in one directory

FLUX.2 Klein 4 B is the fullest bundle the repo produces, and it is worth walking because it exercises
every mechanism the format has.

The component registry has **exactly seven entries** (✅ VERIFIED,
`python/src/coreai_models/diffusion/components.py:292-357`, `FLUX2_COMPONENTS`):
`transformer` → `Transformer`, `transformer_512` → `Transformer_512`, `text_encoder` →
`TextEncoder`, `vae_decoder` → `VAEDecoder`, `vae_decoder_half` → `VAEDecoder_half`, `vae_encoder`
→ `VAEEncoder`, `vae_encoder_half` → `VAEEncoder_half`.

```
FLUX.2-klein-4B/
├── metadata.json          {metadata_version:"0.2", kind:"diffusion",
│                           assets:{transformer, text_encoder, vae_decoder, vae_encoder, …},
│                           diffusion:{prediction_type, image_size, rope_axes_dims, rope_theta,
│                                      batch_norm_eps, guidance_embeds,
│                                      default_steps, default_guidance_scale, …},
│                           source:{…}, compression:{…}, compilation:{…}}
├── Transformer.aimodel/          (or .aimodelc)   # 1024 px — .full / .tiled modes
├── Transformer_512.aimodel/                       #  512 px — .half mode
├── TextEncoder.aimodel/                           # a Qwen3 encoder, not CLIP
├── VAEDecoder.aimodel/                            # .full
├── VAEDecoder_half.aimodel/                       # .half / .tiled
├── VAEEncoder.aimodel/                            # img2img, .full
├── VAEEncoder_half.aimodel/                       # img2img, .half / .tiled
├── tokenizer/                                     # HF dir → AutoTokenizer.from(modelFolder:)
├── vae_bn_mean.npy                                # raw float32 VAE batch-norm statistics
└── vae_bn_var.npy
```

**Three different resolution mechanisms operate on that one directory.** ✅ VERIFIED,
`Pipelines/PipelineDescriptor+CoreAI.swift` and `Pipelines/Flux2Pipeline+Resources.swift`:

1. **Metadata-driven.** `PipelineDescriptor.loadFromMetadata` maps the generic `assets` map onto
   diffusion-specific slots (`:155-160`), with `transformer` and `unet` as aliases:
   ```swift prelude:guide-context
   descriptor.components.unet = assets["transformer"] ?? assets["unet"]
   ```
2. **Explicit-name probing** for the mode-dependent variants, trying `.aimodel` then `.aimodelc`
   (`Flux2Pipeline+Resources.swift:116-126`):
   ```swift illustrative
   private static func resolveAsset(at url: URL, name: String) -> String? {
       let fm = FileManager.default
       let aimodel  = "\(name).aimodel"
       let aimodelc = "\(name).aimodelc"
       if fm.fileExists(atPath: url.appendingPathComponent(aimodel).path)  { return aimodel }
       else if fm.fileExists(atPath: url.appendingPathComponent(aimodelc).path) { return aimodelc }
       return nil
   }
   ```
   **This is where `.aimodelc` gets transparently substituted for `.aimodel`** — the runtime half of
   AOT compilation, and the *only* place in the repo that does it automatically. Everywhere else you
   hand-edit metadata (§2.10).
3. **Filename substring auto-detect** as the last resort when there is no metadata at all
   (`PipelineDescriptor.detect`, `:187-212`) — `textencoder2` before `textencoder`, `unet` /
   `transformer` / `mmdit` into the same slot, and `vaedecoder` **only if the name does not contain
   `half`**, so FLUX.2's `_half` variants stay out of the generic slots.

Mode selection then falls out of *which files exist* (`Flux2Pipeline+Resources.swift:130-144`):
`.full` if `Transformer` + `VAEDecoder`, `.tiled` if `Transformer` + `VAEDecoder_half`, `.half` if
`Transformer_512` + `VAEDecoder_half`, else a `missingComponent` throw that names all three valid
combinations. **So `--platform iOS` at export time and `.half` at runtime meet through nothing but
filenames.** No flag, no metadata field, no version negotiation.

Two more things this bundle teaches:

**Raw `.npy` sidecars are legal, and Swift reads them by hand.** `vae_bn_mean.npy` /
`vae_bn_var.npy` are `np.save`d directly by the exporter (✅ `diffusion/pipeline.py:250-251`) and
parsed by a hand-rolled reader in the Swift package that checks the `\x93NUMPY` magic, branches on
v1 vs v2 header length, and binds the tail as `Float32` — **ignoring the header's declared dtype,
shape and `fortran_order` entirely** (`Flux2Pipeline+Resources.swift:148-171`). It works because the
writer is one line away in the same repo. If you adopt the pattern for your own sidecars, either
copy the *other* `.npy` reader in the repo (the one in `Tools/image-segmenter` handles
float16/float32/int32/uint8 plus shape) or write your own header check. There are two independent
`.npy` readers in this repo and they do not agree.

**`pipeline.json` is now a hard error.** The legacy descriptor file, if present, throws in `.auto`
mode (`PipelineDescriptor.swift:122-129`):

> *"This bundle uses the legacy pipeline.json format which is no longer supported. Please re-export
> with `coreai.diffusion.export` to produce metadata.json."*

Any blog post or README snippet you find that mentions `pipeline.json` predates schema 0.2.

### 2.9 ⚠️ `BundleKind` has four cases, and the repo ships six model families

The complete enumeration. ✅ VERIFIED, `CoreAIShared/Bundle/BundleKind.swift:11-16`:

```swift compile:27
/// Top-level model categories the runner ecosystem knows about.
///
/// The bundle's `kind` selects which kind-specific config block (and which
/// kind-specific Swift type — `LanguageBundle`, `DiffusionBundle`, etc.) is
/// expected on top of the common `ModelBundle`.
public enum BundleKind: String, Codable, Sendable, CaseIterable {
    case llm
    case vlm
    case diffusion
    case segmenter
}
```

Note what is **absent: there is no `.speech` and no `.detector`.** And the package ships
`CoreAISpeech` and `CoreAIObjectDetection` as first-class products. Both load directories **by
convention, with no `metadata.json` at all.**

`SpeechBundle` hard-codes filenames (✅ `CoreAISpeech/SpeechBundle.swift:28-46`):

```
<bundle-dir>/
  encoder.aimodel           REQUIRED — audio features → encoder hidden states
  decoder.aimodel           REQUIRED — autoregressive decoder with persistent KV state
  generation_config.json    optional — falls back to GenerationConfig.whisper
  tokenizer.json            optional — else falls back to the HF cache
```

and throws if either asset is missing:

```swift prelude:guide-context
throw SpeechError.missingModel(
    "bundle at \(url.lastPathComponent) must contain encoder.aimodel and decoder.aimodel")
```

> ⚠️ **Nothing in this repository produces that split.** `models/whisper/export.py` emits a **single**
> `.aimodel` with one `main` function — which matches `speech-runner`'s *legacy* monolithic path, not
> `SpeechBundle`. So the required bundle shape for the shipped `SpeechModel` actor has **no
> exporter**. Corroborating signals: there is no `SpeechTests` target in `Package.swift`, and
> `CoreAISpeech` is the one product missing from `.spi.yml`'s documentation list.
>
> 🔴 **GAP:** where the encoder/decoder split export lives — an unshipped internal tool, a future
> commit, or an oversight — is **unverified**. **Safe default: treat `CoreAISpeech` as
> pre-release.** If you need on-device ASR today, use the `SpeechAnalyzer` / `SpeechTranscriber`
> system APIs (Part 16), or run Whisper through the single-`main` legacy path in `speech-runner`
> which the shipped exporter does produce. Do not design a bundle-installation pipeline around
> `SpeechBundle`'s layout until an exporter for it exists.

The lesson generalises. **`BundleKind` is not a taxonomy of what Core AI can run — it is a list of
which runners chose to use `ModelBundle`.** Object detection loads a bare `.aimodel` with no bundle
at all. Ten of the fifteen non-LLM models in the catalog produce no bundle. If you are writing an
installer that dispatches on `kind`, budget for "no metadata.json, figure it out from the
filenames," because that is what half the catalog looks like.

### 2.10 After AOT compilation, you must hand-edit `metadata.json`

`xcrun coreai-build compile` turns `Model.aimodel` into one or more `Model.<arch>.aimodelc`. The
bundle does not update itself. `models/README.md:173` is unambiguous:

> *"Models can optionally be ahead-of-time compiled. Run `xcrun coreai-build compile --help` for
> usage. If you compile a model, replace the corresponding asset in the bundle directory and update
> `metadata.json` to reference the new filename."*

> ✅ **Availability, resolved 2026-07-31:** `coreai-build` **is runnable after all** — it ships in
> the optional **Metal Toolchain component** (`xcodebuild -downloadComponent MetalToolchain`), not
> in Xcode-beta.app itself. The 2026-07-29 Xcode 27 beta installation did not have that component,
> so `xcrun --find coreai-build` failed; that result described the installation, not the Xcode
> release. With the component installed the `--help` Apple's README
> points at runs and is captured in `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`; see
> 7.2 §13 for the full surface.

The reader's error message spells out the fix (✅ `ModelBundle.swift:103-109`):

> `Asset 'main' not found at …. If you compiled this model with 'xcrun coreai-build compile', update
> metadata.json "assets" to reference the compiled filename (e.g. modelName.architectureName.aimodelc).
> See models/README.md#compiled-models`

Note `modelName.architectureName.aimodelc` — the compiled filename carries the **target
architecture**, because AOT emits one artifact per architecture and your app picks at runtime. So a
bundle that ships compiled assets for three architectures needs either three bundles or three
`assets` maps.

A 30-line post-compile step, since you will write one anyway:

```swift compile:27
import Foundation

/// Rewrites `assets.<role>` in a bundle's metadata.json to point at a compiled asset.
/// Preserves every other key, including ones this code has never heard of.
func retargetBundleAsset(
    bundleDirectory: URL,
    role: String,
    compiledFilename: String
) throws {
    let metadataURL = bundleDirectory.appending(path: "metadata.json")
    let data = try Data(contentsOf: metadataURL)

    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    var assets = root["assets"] as? [String: Any] ?? [:]
    assets[role] = compiledFilename
    root["assets"] = assets

    // Record what happened, in the block the schema already reserves for it.
    var compilation = root["compilation"] as? [String: Any] ?? [:]
    var targets = compilation["targets"] as? [Any] ?? []
    targets.append(compiledFilename)
    compilation["targets"] = targets
    root["compilation"] = compilation

    let out = try JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: metadataURL, options: .atomic)
}
```

Two deliberate choices there. It round-trips through `JSONSerialization` rather than a `Codable`
struct, because a `Codable` model of the schema would **drop every key it does not declare** — and
the schema is open at the top level (§2.2). And it appends to `compilation.targets`, the array the
LLM exporter writes empty and nothing else ever fills. That is what it is for.

### 2.11 ⚠️ SILENT FAILURE — `compression` records the request, not the result

Here is the one that will cost you a day.

The diffusion export's quantization step is wrapped in a bare `except` that logs a **warning** and
returns the *unmodified* program. ✅ VERIFIED verbatim, `python/src/coreai_models/export/compiler.py:57-73`:

```python
if quant_type == "int4":
    try:
        coreai_program = quantize_weights(
            coreai_program,
            dtype=DType.INT4,
            qscheme=QScheme.SYMMETRIC if symmetric else QScheme.ASYMMETRIC,
            granularity=_GRANULARITY_MAP[granularity],
            block_size=block_size,
            weight_num_threshold=32768,
            in_place=True,
        )
        logger.info("Applied INT4 weight quantization")
    except ImportError:
        logger.warning("Core AI quantization not available, skipping quantization")
    except Exception as e:
        logger.warning(f"Quantization failed: {e}")
else:
    logger.warning(f"Unsupported quantization type: {quant_type}")

return coreai_program
```

Meanwhile the metadata writer records the **requested** setting, unconditionally
(✅ `diffusion/pipeline.py:340`):

```python
"compression": compression if compression != "none" else None,
```

Put those together. `uv run coreai.diffusion.export flux2-klein-4b --compression 4bit` on a machine
where `quantize_weights` raises — a `coreai-opt` version skew, an unsupported op, an OOM inside the
quantizer — produces:

- **exit code 0**
- a bundle whose `metadata.json` says `"compression": "4bit"`
- a **float16** artifact roughly **4× the intended size**
- one `WARNING` line, in the middle of several minutes of export logs

Nothing downstream re-derives compression from the weights. The Swift side never checks. The **only
signal is file size**, and only if you know what to expect.

The same pattern recurs in the sidecar writer. The FLUX.2 tokenizer save is wrapped in
`except Exception as e: logger.warning(f"Could not save tokenizer: {e}")`, and so is the VAE
batch-norm `.npy` write (✅ `diffusion/pipeline.py:243-253`). A bundle can therefore ship with a
`tokenizer/` directory that is absent or half-written, and — via §2.7's fallback — still work
perfectly on the exporting machine.

**Defence, and it is worth automating:**

```bash
# 1. Size gate. A 4-bit export must be ≈4× smaller than fp16. Compare, don't trust.
du -sh exports/flux2_klein_4b_4bit/*.aimodel

# 2. Grep the export log for the words that mean "silently didn't".
uv run coreai.diffusion.export flux2-klein-4b --compression 4bit 2>&1 | tee export.log
grep -iE 'quantization failed|skipping quantization|could not save|unsupported' export.log && exit 1

# 3. Assert the bundle is complete before you ship it.
test -f exports/flux2_klein_4b_4bit/tokenizer/tokenizer.json || exit 1
```

and in Swift, at install time rather than first use:

```swift prelude:guide-context
let bundle = try ModelBundle(at: bundleURL)
try bundle.verify()                                  // every declared asset exists
let lang = try LanguageBundle(bundle: bundle)
precondition(lang.hasEmbeddedTokenizer,              // no silent network fetch (§2.7)
             "bundle \(lang.name) has no embedded tokenizer")
```

> 🔴 **GAP — does `metadata.json` ever record *achieved* compression?** No writer in the repo emits
> anything but the requested preset name, and no reader validates it. Whether `AIModelAssetMetadata`
> inside the `.aimodel` carries the real numeric format is **unverified** — resolving it needs an
> SDK-level dump of a compiled asset's metadata, or `AIModelAsset.summary(includingStatistics: true)`
> output, which nobody in this corpus has captured. **Safe default: treat `metadata.json`'s
> `compression` field as a build *request*, never as a claim about the bytes, and gate on artifact
> size in CI.**

### 2.12 Bundle format quick reference

| Key | Type | Required | Read by | Notes |
|---|---|---|---|---|
| `metadata_version` | string | effectively | `ModelBundle` | must equal `"0.2"`; absent ⇒ `"0.1"` ⇒ throw |
| `kind` | `llm\|vlm\|diffusion\|segmenter` | ✅ | `ModelBundle` | no `speech`, no `detector` |
| `name` | string | ✅ | `ModelBundle` | used as `modelIdentifier` in the executor cache key |
| `assets` | `{role: filename}` | ✅ in practice | `ModelBundle` | defaults to `[:]` if absent; roles are open |
| `user_data` | `{string: string}` | — | `ModelBundle` | **no writer emits it; it is yours** |
| `language` | object | ✅ for llm/vlm | `LanguageBundle` | see §2.6 |
| `vision` | object | ✅ for vlm | `LanguageBundle` | **top level, not inside `language`** |
| `diffusion` | object | ✅ for diffusion | `PipelineDescriptor` | snake_case, `.convertFromSnakeCase` |
| `source` | `{model_definition, hf_model_id}` | — | nothing | provenance |
| `compression` | string or null | — | nothing | ⚠️ the *request* (§2.11) |
| `compilation` | `{date, targets[]}` | — | nothing | `targets` always written empty |

**Rules that are not negotiable:**

1. Point loaders at the **directory**, never at the `.aimodel`.
2. `metadata_version` is exactly `"0.2"`.
3. `.aimodel` and `.aimodelc` are directories; `.aimodelc` has its own unrelated `metadata.json`.
4. After AOT compilation, edit `assets` yourself.
5. Ship `tokenizer/`, and assert it exists.
6. Treat `compression` as a request.

---

## 3. The Swift package: five products, three dependencies

### 3.1 The manifest

✅ VERIFIED verbatim, `Package.swift:1`, `:10-46`:

```swift illustrative
// swift-tools-version: 6.0

let package = Package(
    name: "coreai-models",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "CoreAILM",              targets: ["CoreAILanguageModels"]),
        .library(name: "CoreAIDiffusion",       targets: ["CoreAIDiffusionPipeline"]),
        .library(name: "CoreAISegmentation",    targets: ["CoreAIImageSegmenter"]),
        .library(name: "CoreAISpeech",          targets: ["CoreAISpeech"]),
        .library(name: "CoreAIObjectDetection", targets: ["CoreAIObjectDetector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.0"),
        .package(url: "https://github.com/mlc-ai/xgrammar", branch: "main"),
    ],
    …
```

**Product name ≠ target name ≠ module name, and this will bite you.** In four of five cases they all
differ. This is the table to keep:

| Product (what you add in Xcode) | Target | **Module you `import`** | Dependencies |
|---|---|---|---|
| `CoreAILM` | `CoreAILanguageModels` | **`CoreAILanguageModels`** | `CoreAIShared`, `CXGrammar`, `Transformers` |
| `CoreAIDiffusion` | `CoreAIDiffusionPipeline` | **`CoreAIDiffusionPipeline`** | `CoreAIShared`, `Transformers` |
| `CoreAISegmentation` | `CoreAIImageSegmenter` | **`CoreAIImageSegmenter`** | `CoreAIShared` only |
| `CoreAISpeech` | `CoreAISpeech` | `CoreAISpeech` | `CoreAIShared`, `Transformers` |
| `CoreAIObjectDetection` | `CoreAIObjectDetector` | **`CoreAIObjectDetector`** | `CoreAIShared` only |

✅ VERIFIED, `Package.swift:14-41` (products) and `:49-117` (targets).

Session 326 says, correctly, *"we can select the **CoreAILM** and **CoreAISegmentation** to my app
target"* (326:98, 🟡 spoken narration, ✅ product names confirmed against the manifest). Then the
import line is `import CoreAILanguageModels` — as Apple's own model READMEs show. Meanwhile
`models/sam3/README.md` says `import ImageSegmenter`, which is **neither** a product nor a target
nor a module and does not compile. Apple's own README is wrong; use `import CoreAIImageSegmenter`.

Also note **`CoreAISegmentation` and `CoreAIObjectDetection` have zero third-party dependencies** —
they reach only `CoreAIShared`, which itself declares `dependencies: []`. That makes them the
cleanest available templates for "run a vision model on Core AI with nothing but the OS
frameworks." `CoreAILM` cannot say that: it pulls swift-transformers (which transitively pulls
swift-huggingface, swift-jinja, swift-nio, swift-collections, swift-crypto, swift-atomics,
swift-asn1, swift-system, EventSource and yyjson, per `Package.resolved`) plus xgrammar's C++.

### 3.2 The dependency that should make you nervous

```swift illustrative
.package(url: "https://github.com/mlc-ai/xgrammar", branch: "main"),
```

✅ VERIFIED, `Package.swift:46`. And in `Package.resolved` (`:104-110`):

```json
{
  "identity" : "xgrammar",
  "kind" : "remoteSourceControl",
  "location" : "https://github.com/mlc-ai/xgrammar",
  "state" : {
    "branch" : "main",
    "revision" : "4d145cc13d878c751ebeed36af1c013074be76bc"
  }
}
```

**A `branch:` requirement, not a version range.** A `swift package update` in your project moves
Apple's grammar engine to whatever is on `mlc-ai/xgrammar`'s `main` that day. There is no semver
gate, no upper bound, and no Apple-side pin beyond the `Package.resolved` you happen to have
checked in.

**Do this:**

```bash
# Commit Package.resolved. Then, in CI, prove it did not move:
git diff --exit-code Package.resolved || {
    echo "Package.resolved changed — an unpinned dependency moved. Review before merging."
    exit 1
}
```

and if you vendor `coreai-models` into a monorepo, consider replacing the branch requirement with
`.revision("4d145cc13d878c751ebeed36af1c013074be76bc")` in your own fork's manifest. The community
`john-rocky/coreai-models` fork went further and **vendors a prebuilt `CXGrammar.xcframework`**
(`libxgrammar_ios.a` + `libxgrammar_macos.a` for `ios-arm64_arm64e` and `macos-arm64_arm64e`) so
downstream consumers need no C++ toolchain at all — community-authored, not Apple, but a reasonable
pattern if SwiftPM consumability matters to you.

The commit history explains the shape: `277238e` "Remove notice file as we have adopted upstream
Swift package for xgrammar (#45)" — so this dependency used to be vendored source and became a
package reference. It is young.

### 3.3 `CoreAILanguageModels` is a table of contents for an LLM runtime

If you have ever wondered what actually has to exist between "I have a transformer" and "I have a
chat app," this directory listing is the answer. ✅ VERIFIED — this is `ls` on
`swift/Sources/CoreAILanguageModels/` at commit `5ed9981`:

```
Assets/              ModelPaths.swift
Bundle/              LanguageBundle.swift · LanguageConfig.swift · ModelBundle+Language.swift
DecodingStrategies/  ConstrainedDecodingStrategy.swift · ConstrainedGenerator.swift
                     ContinuationEvaluation.swift · DecodingStrategy.swift
                     VanillaDecodingStrategy.swift
GuidedGeneration/    ConstrainedGenerationSession.swift · TokenizerInfo.swift · XGrammarWrapper.swift
InferenceEngines/    CoreAIPipelinedEngine.swift · CoreAISequentialEngine.swift
                     CoreAISequentialVLMEngine.swift · CoreAIStaticShapeEngine.swift
                     EmbeddedInput.swift · EngineFactory.swift · GenerationToken.swift
                     InferenceEngine.swift · InferenceOutputSequence.swift
                     KVCache+CoreAI.swift · KVCacheShared.swift · ModelConfig.swift
                     TensorStorage+CoreAI.swift · TokenHistory.swift
LanguageModel/       CoreAILanguageModel.swift · CoreAIRunner.swift · ModelResources.swift
                     ThinkTagParser.swift
Output/              LogitsWriter.swift
Profiling/           InstrumentsProfiler.swift · PerformanceMetrics.swift · Timing.swift
Samplers/            CompositeSampler.swift · MPSGraphSamplers.swift · SamplingConfiguration.swift
Session/             TokenizerLoader.swift
TextGeneration/      PromptProcessing.swift · TextGenerator.swift
VLM/                 CoreAIVisionLanguageModel.swift
ModelShapeConfig.swift
ToolCallParser.swift
```

Twelve directories. Read them as a layered stack:

| Layer | Directories | What it owns |
|---|---|---|
| **Resource resolution** | `Assets/`, `Bundle/` | finding the bundle on disk; parsing schema 0.2 |
| **Execution** | `InferenceEngines/` | four engines, engine selection, KV cache, token history |
| **Token choice** | `Samplers/`, `GuidedGeneration/` | temperature/topK/topP/minP on CPU and GPU; grammar masks |
| **Loop orchestration** | `DecodingStrategies/`, `TextGeneration/` | what to do per step; stop sequences; prompt templating |
| **Public façades** | `LanguageModel/`, `VLM/` | the Foundation Models conformance |
| **Observability** | `Profiling/`, `Output/` | Instruments spans, token counts, logits dumps |
| **Support** | `Session/`, `ToolCallParser.swift`, `ModelShapeConfig.swift` | tokenizer loading, tool-call and think-tag stream parsing, shape selection |

Two of those exist for reasons that are not obvious until you hit them.

**`ToolCallParser.swift` and `ThinkTagParser.swift` are streaming parsers, not regexes.** They hold
back at most `closeMarker.count - 1` characters so a `</think>` straddling two token deltas is not
truncated. Every marker-based stream parser you write needs that; these two are worth copying.

**`Output/LogitsWriter.swift` exists because you will need to prove numeric parity.** It backs
`llm-runner --save-logits <path> --save-logits-length {1…20|full}`, which is how you compare a Core
AI export against the PyTorch original token by token. Part 8 and Part 9 lean on it.

### 3.4 The six CLI tools, and what each is actually for

`Package.swift:130-200` declares six executables. They are the only "sample code" this framework
has, so learn what they answer:

```bash
swift run -c release llm-runner       --model path/to/bundle_dir --prompt "Hello"
swift run -c release llm-benchmark    --model path/to/bundle_dir      # -p 512 -g 1024 -n 5
swift run -c release diffusion-runner --model DIR --prompt "…" --steps 4 --guidance-scale 1.0
swift run -c release image-segmenter  --model DIR --prompt "cat" --image photo.jpg
swift run -c release object-detector  --model model.aimodel --image photo.jpg
swift run -c release speech-runner    <bundleDirOrAimodel> [audio.wav]
```

> ⚠️ **`swift run` defaults to Debug, and Debug is not slow-but-correct here — it is catastrophically
> slow.** `llm-benchmark` prints a warning when built in DEBUG for a reason. The concrete case from
> the source: `zeroFill` on the sequential engine's KV cache used to go through
> `fillNDArray`'s `(Int) -> LogitsScalarType` closure, which under `-Onone` is invoked *per element*
> — making a `reset()` on a 32 K-context Qwen3 cache (~14.7 M elements) take **~6 seconds**
> (✅ comment at `CoreAISequentialEngine.swift`, in the hand-rolled pointer loop that replaced it).
> Always `-c release`.

> ⚠️ **`Tools/benchmark` is `llm-benchmark`, and it imports `CoreAILanguageModels`.** There is **no
> non-LLM benchmark tool in the repo, and no published quality or latency number for any vision,
> audio or diffusion model in the catalog.** If you need to know whether SAM 3 lite at 4-bit is good
> enough, you have to measure it; nobody has published it.

`llm-runner` is the interesting one, because its flag list is a map of every knob this layer has.
The ones that matter for this guide (✅ `Tools/llm-runner/LLMRunnerMain.swift`, option declarations):

```
--inference-engine-variant STR   default "default"; {auto|default|coreai-sequential|coreai-pipelined|static-shape}
--kv-cache-strategy {auto,growing,chunked,fixed_size}    default auto
--kv-cache-initial-capacity INT
--json-schema STRING|PATH        constrained generation (§7)
--sampling-strategy {temperature,greedy}    default "temperature"
--temperature DOUBLE             default 0.7
--top-k INT · --top-p DOUBLE · --min-p DOUBLE
--synchronous-sampling           sets SamplingConfiguration.combined = false
--save-logits PATH · --save-logits-length {1..20|full} · --print-logits
--continuation TEXT              requires --apply-chat-template=false AND a logits flag
--warmup {default,off,none,exact} · --warmup-length INT  (hidden)
--bucket-size INT                hidden; sets env COREAI_QUERY_BUCKET_SIZE (0 disables, default 64)
--chunk-size INT                 hidden; sets env COREAI_CHUNK_THRESHOLD (default 1024, "use 128 for MoE")
```

Two hidden flags there are environment variables in disguise, which means **you can set them from
your app** without going near the CLI:

```swift compile:27 imports:Foundation
setenv("COREAI_CHUNK_THRESHOLD", "128", 1)   // BEFORE the engine is created
```

`COREAI_CHUNK_THRESHOLD` is read by `ModelConfig` (✅ `ModelConfig.swift`, `chunkThreshold` reads the
env var when > 0, else 1024; `prefillChunkSize` is `min(512, chunkThreshold)`). It is a **memory
dial for prefill**, and §5.7 covers what to set it to.

> 🔴 **GAP — `COREAI_QUERY_BUCKET_SIZE` is set but never read.** `--bucket-size` writes it, and
> **nothing in this repository's Swift reads it back.** It is presumably consumed inside the
> `CoreAI` framework itself. Its default is documented as 64 and 0 is documented as "disables," and
> that is the entire published surface. **Safe default: leave it alone.** Resolving this needs
> either Core AI framework headers or an Instruments trace showing shape-bucketing behaviour change
> across values.

---

## 4. Loading: `CoreAIRunner`, `PreparedModel`, `ModelResources`

Three types stand between `metadata.json` and a running engine. You can use all three directly, and
`CoreAILanguageModel` (§8) is a thin shell over them.

### 4.1 `CoreAIRunner` — bundle in, engine out

The entire type. ✅ VERIFIED, `LanguageModel/CoreAIRunner.swift:19-88`:

```swift prelude:guide-context
public struct CoreAIRunner {
    public init(contentsOf url: URL,
                variant: String? = nil,
                kvCacheStrategy: KVCacheStrategy = .auto) throws
    public init(bundle: LanguageBundle,
                variant: String? = nil,
                kvCacheStrategy: KVCacheStrategy = .auto)

    public func makeInferenceEngine() async throws -> any InferenceEngine
}
```

> ⚠️ **The `bundle:` label is new.** Commit `102f832` "Polish a few APIs, method names…" (#122,
> 2026-07-23) renamed `CoreAIRunner.init(from bundle:)` → `init(bundle:)`. Any snippet you find
> using `CoreAIRunner(from:)` predates that commit by less than a week. The same commit renamed
> `PerformanceMetrics.setPromptTokenCount(_:)` → `recordPromptTokens(_:)`,
> `setGeneratedTokenCount(_:)` → `recordGeneratedTokens(_:)`, made `getGeneratedTokenCount` into a
> `public private(set) var generatedTokenCount`, replaced `CLILogger.setLevel(to:)` with a settable
> `public static var CLILogger.level`, and **un-published `Duration.inSeconds` / `.inMilliseconds`**
> with the rationale *"vending members on a standard-library type we don't own would pollute
> `Duration`'s API surface for every client of this library."* This layer's API is still moving.

`makeInferenceEngine()` builds a `ModelConfig` out of the bundle, JSON-encodes it, and hands it to
`EngineFactory` along with `assets.main`'s URL (✅ `:55-69`). That is the whole handoff: the engine
factory never sees your bundle, only a config blob and a model URL.

### 4.2 `PreparedModel` — the two-phase load that picks your compute unit

This is the most reusable single idea in the repo, and it lives in `CoreAIShared` where any product
can use it. ✅ VERIFIED verbatim, `CoreAIShared/Runtime/ModelStructure.swift:145-165`:

```swift illustrative
public static func prepare(at url: URL) async throws -> PreparedModel {
    CLILogger.log("PreparedModelAsset: Preparing \(url.lastPathComponent)")
    // Probe structure before specializing so we can pick the right compute-unit preference.
    let probedStructure = probeStructure(at: url)
    CLILogger.log("  - Probed structure: \(probedStructure.description)")
    let options = probedStructure.specializationOptions
    let model = try await AIModel(contentsOf: url, options: options)
    CLILogger.log("  - Loaded \(model.functionNames.count) graphs")
    // Re-detect from compiled library — source of truth, should match the probe.
    let structure = detectStructure(from: model.functionNames)
    return PreparedModel(model: model, structure: structure)
}
```

The probe is cheap because it reads **the asset's summary without specializing**
(`ModelStructure.swift:170-185`):

```swift illustrative
let asset = try AIModelAsset(contentsOf: url)
if let summary = try asset.summary(includingStatistics: false) {
    let names = summary.functions.map(\.name)
    …
}
```

`AIModelAsset.summary(includingStatistics:)` is the API to remember. It gets you the function list —
which is the model's *shape*, structurally — before you commit to the expensive specialization step.

The names it looks for (✅ `ModelStructure.swift:12-20`):

```swift prelude:guide-context
public enum GraphNames {
    public static let main = "main"
    public static let loadEmbeddings = "load_embeddings"
    public static let extendPrefix = "extend"
    // Multi-function segmenter (lite SAM3 export for iOS).
    public static let imageEncode = "image_encode"
    public static let textEncode = "text_encode"
    public static let detect = "detect"
}

public enum ModelStructure: Equatable, Sendable, CustomStringConvertible {
    case chunkedStatic(batchSize: Int)   // has extend_* AND load_embeddings
    case dynamic                          // has main
    case multiFunctionSegmenter           // has image_encode AND text_encode AND detect
}
```

Detection order is load-bearing and commented (`:190-218`):

1. `extend*` **and** `load_embeddings` → `.chunkedStatic(batchSize:)`, batch parsed out of
   `extend_<context>_<batch>` by splitting on `_` and taking index 2.
2. `image_encode` ∧ `text_encode` ∧ `detect` → `.multiFunctionSegmenter`. Checked **before** the
   `main` fallback because *"some asset variants ship a thin `main` graph alongside the trio."*
3. `main` → `.dynamic`.
4. otherwise → `.dynamic`, with a warning.

**And here is the sample helper’s payoff — structure chooses the preference it supplies.** ✅
VERIFIED verbatim, `ModelStructure.swift:57-80`:

```swift prelude:guide-context
public var preferredDevice: String {
    switch self {
    case .chunkedStatic, .multiFunctionSegmenter: return "NeuralEngine"
    case .dynamic:                                 return "GPU"
    }
}

public var specializationOptions: SpecializationOptions {
    switch self {
    case .chunkedStatic, .multiFunctionSegmenter:
        return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    case .dynamic:
        var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
        opts.expectFrequentReshapes = true
        return opts
    }
}
```

Read that with §1.1. **When you use `coreai-models.PreparedModel`, splitting SAM 3 into the three
recognized entrypoints selects that helper’s Neural Engine preference in addition to enabling
different cadences.** A single-`main` SAM 3 export is classified `.dynamic` and receives its GPU
preference. Direct Core AI loaders are not governed by these names.[^sample-routing-policy] WWDC26
session 325 presents the split as a way to run each stage at a different cadence (76% faster second
inference, Apple-published, hardware unstated 🟡).

The same logic explains the iOS-vs-macOS LLM split. The iOS export emits `load_embeddings`,
`gather_embeddings_<q>`, `extend_<ctx>_<q>` and `prompt_opt_<ctx>_<q>` — so it is `.chunkedStatic`,
so it gets `preferredComputeUnitKind: .neuralEngine`. The macOS export emits one `main` — so it is
`.dynamic`, so it gets `.gpu` **plus `expectFrequentReshapes = true`**, which is exactly right for a
graph whose sequence dimension changes every prefill chunk.

⚠️ Two failure modes in the probe worth knowing:

- **The probe swallows errors and defaults to `.dynamic`.** If `AIModelAsset(contentsOf:)` throws or
  the summary comes back empty, you silently get `.dynamic` — which means **GPU specialization for a
  model you meant to run on the ANE**. The log line `"Probe (summary) returned empty; defaulting to
  .dynamic"` at verbosity ≥ 1 is your only warning. Run `llm-runner --verbose` once against a new
  bundle and read the `- Probed structure:` line.
- **`resolveCoreAIModelURL(from:)` silently redirects.** If the URL you pass is not a `.aimodel`, it
  looks for a sibling `<basename>.aimodel` and logs the redirect (`:111-132`). Convenient, and also a
  way to load a different asset than you thought you asked for.

### 4.3 `ModelResources` — lazy loading, shared engines, borrow-safe unload

Introduced by commit `eb3998e` "Lazy runner design: defer engine load (#91)". It is `internal`, so
you cannot instantiate it directly, but its behaviour is the reason `CoreAILanguageModel` behaves the
way it does and you need to know all four properties.

**1. Loading is lazy by default and deduplicated.** `CoreAILanguageModel.init(resourcesAt:)` defaults
to `mode: .lazy`; `engine()` loads on first use and concurrent callers share one in-flight load
(✅ `ModelResources.swift:45-53`). **Failures are not cached** — the task is dropped so the next
caller retries.

**2. Engines are shared process-wide, keyed by the executor `Configuration`.**
`ModelResources.shared(for:)` is a process-wide registry holding values in a `WeakBox`, so releasing
the last model releases the engine. The key is `CoreAIExecutor.Configuration`, which is
`Hashable` over `(url, variant, kvCacheStrategy, modelIdentifier, samplingConfig, vocabSize)`
(✅ `CoreAILanguageModel.swift:151-158`).

> ⚠️ **Two `CoreAILanguageModel`s built from the same URL with the same settings share one engine —
> and therefore one KV cache.** That is a feature when you want it and a corruption bug when you do
> not. Community-measured on a comparable setup: *"Two `LanguageModelSession`s over the same model
> **corrupt the KV state** (the second resets the engine under the first). A per-turn fresh
> classifier session is the classic way to trip this — reuse one router session."* Attribute:
> community (`john-rocky/coreai-model-zoo` `knowledge/dynamic-profiles-local-models.md`,
> macOS 27 beta, M-series Mac, 2026-06-13), not an Apple statement. The mechanism — a shared,
> configuration-keyed executor — is ✅ verified in Apple's source; the corruption symptom is the
> community claim. **If you need two independent conversations, vary something in the
> `Configuration`** (the simplest lever is `samplingConfig`) **or serialize them.**

**3. Unload is borrow-counted.** `withEngine { … }` increments `activeBorrows`; a concurrent
`unloadResources()` sets `unloadPending` and defers teardown until the last borrow returns, *"so the
engine is never freed mid-generation."* So `model.unload()` during a stream is safe and takes effect
when the stream ends.

**4. Load includes a warmup.** `loadEngine` runs `CoreAIRunner(contentsOf:variant:kvCacheStrategy:)`
→ `makeInferenceEngine()` → `try await engine.warmup(queryLength: 1, sampling: nil)`.

That last point has a sharp edge on decode-only bundles. Community-reported (same source): a bundle
whose graph accepts only `S=1` rejects the default warmup shape, so *"never call `engine.warmup()`
with the default query length on them (warms `S=256`, which the `S=1` graph rejects)"* and set
`COREAI_CHUNK_THRESHOLD=1` before engine creation. Apple's own warmup here uses `queryLength: 1`, so
the adapter path is fine; the hazard is on the direct-engine path if you call `warmup` yourself.

A worked direct-engine load, which is what you write when you do **not** want Foundation Models:

```swift prelude:external-module
import CoreAILanguageModels
import CoreAIShared
import Foundation

let bundleURL = URL(fileURLWithPath: "exports/qwen3_0_6b_4bit_dynamic")

// 1. Parse and validate the bundle before touching the model.
let bundle = try LanguageBundle(at: bundleURL)
try bundle.bundle.verify()
precondition(bundle.hasEmbeddedTokenizer, "no embedded tokenizer in \(bundle.name)")
print("\(bundle.name): vocab \(bundle.vocabSize), ctx \(bundle.maxContextLength)")

// 2. Load the tokenizer and the engine. These are independent — do them concurrently.
async let tokenizerLoad = bundle.loadTokenizer()
async let engineLoad = CoreAIRunner(bundle: bundle).makeInferenceEngine()
let tokenizer = try await tokenizerLoad
let engine = try await engineLoad

print("engine supportsLogits: \(engine.supportsLogits)")   // decides §7 for you
```

`CoreAILanguageModel.init` does exactly this — `async let` for the engine, then the tokenizer, then
`try await engineLoad` (✅ `CoreAILanguageModel.swift:111-122`).

> ⚠️ One divergence in Apple's own code, worth knowing if you build a VLM path. `llm-runner` loads a
> VLM's three sub-models **sequentially**, with the comment *"Sequential to avoid runtime errors with
> concurrent model preparation."* `CoreAIVisionLanguageModel.init` loads them **concurrently** with
> `async let`. One of the two is wrong and the repo does not say which. 🔴 **GAP.** **Safe default:
> load multi-asset bundles sequentially** — you pay a few hundred milliseconds once and avoid a class
> of error the repo's own CLI author went out of their way to dodge.

---

## 5. The engines

### 5.1 The protocol

One protocol, four conformers. ✅ VERIFIED verbatim,
`InferenceEngines/InferenceEngine.swift:87-149`:

```swift illustrative
/// Interface for inference engines.
///
/// KV cache is preserved between `generate()` calls. Call `reset()` to clear.
public protocol InferenceEngine: Sendable {
    associatedtype OutputSequence: InferenceOutputSequence
    typealias TokenId = Int32

    // MARK: - Primary API

    func generate(
        with input: [TokenId],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> OutputSequence

    // MARK: - Lifecycle

    /// Number of tokens the engine has processed in the current session.
    var processedTokenCount: Int { get }

    /// Reset KV cache to the state after processing `tokenIndex` tokens.
    /// - tokenIndex == 0: full reset (clear all state, equivalent to reset())
    /// - tokenIndex > 0: partial reset (keep cache for first tokenIndex positions)
    func reset(to tokenIndex: Int) async throws

    /// Run dummy inference to trigger kernel compilation.
    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws

    // MARK: - Cancellation

    var isBusy: Bool { get }
    func cancel() async throws

    // MARK: - Capabilities

    /// Whether this engine supports per-step logits extraction.
    /// GPU-pipelined engines (which sample on-device) return false.
    var supportsLogits: Bool { get }

    /// How many tokens were reused from cache on the last `generate()` call.
    var lastPrefixHitCount: Int { get }

    // MARK: - Configuration

    associatedtype ConfigType: Codable, InferenceConfiguration
    var config: ConfigType { get }
}
```

with these protocol-extension defaults (`:183-231`): `supportsLogits` → `false`,
`lastPrefixHitCount` → `0`, `isBusy` → `false`, `cancel()` → no-op, `warmup(queryLength:sampling:)`
→ no-op, `processedTokenCount` → `0`, `reset()` → `reset(to: 0)`, and
`validateSamplingStrategy(_:)` → accepts everything.

Note the defaults' direction: **every capability defaults to "no."** A minimal conformer that
implements only `generate` and `reset(to:)` compiles, reports no logits, no prefix caching, no
cancellation, and no busy state. That is a good design — it means a new engine cannot accidentally
claim a capability — and it also means `supportsLogits` is the one property you must read before
building anything on top.

The two supporting types (✅ `:20-53`):

```swift prelude:guide-context
public struct InferenceOutput: Sendable {
    public let tokenId: Int32
    /// Populated when `InferenceOptions.includeLogits` is true. Shape: [vocabSize].
    public let logits: [LogitsScalarType]?
}

public struct InferenceOptions: Sendable {
    /// Max tokens to generate. Nil = until EOS or context limit.
    public var maxTokens: Int?
    /// Include raw logits in each `InferenceOutput`. May incur GPU→CPU copy cost.
    public var includeLogits: Bool
    /// When set, engines use these token IDs instead of sampling.
    /// Used by MMLU-style evaluation to compute P(continuation|context).
    public var forcedContinuation: [Int32]?
}
```

`forcedContinuation` is worth pausing on: it is a **teacher-forcing** switch. Hand it the tokens of a
candidate answer and the engine runs them through instead of sampling, giving you the logits at each
position — i.e. `P(continuation | context)`, the MMLU/HellaSwag scoring primitive. It is the only
evaluation hook this layer has, and like `includeLogits`, **the pipelined engine rejects it.**

And the output sequence protocol, which is how you learn *why* generation stopped
(✅ `InferenceOutputSequence.swift`):

```swift illustrative
public enum StopReason: Sendable, Equatable {
    case maxTokens, eos, stopSequence(String), cancelled, error
}
public protocol InferenceOutputSequence: AsyncSequence<InferenceOutput, any Error> {
    var stopReason: StopReason? { get }
    func setStopReason(_ reason: StopReason)
}
```

Read `stopReason` **after** the `for try await` loop, not during it. `StopReasonStore` is a
`Mutex`-backed reference box precisely so the value survives the value-typed sequence, and engines
use `setIfUnset` on natural exhaustion so a consumer's `.eos` is not clobbered by `.maxTokens`.

### 5.2 The three variants, and how one is chosen

✅ VERIFIED, `EngineFactory.swift:297-306`:

```swift compile:27
private enum Variant: String, Sendable, CaseIterable {
    case sequential = "coreai-sequential"    // Core AI sequential engine (clean public API rewrite)
    case pipelined  = "coreai-pipelined"     // Core AI pipelined engine (GPU)
    case staticShape = "static-shape"        // Static-shape engine (chunked static, Neural Engine)
}
```

`EngineFactory.createEngine(config:modelURL:options:)` runs five steps
(✅ `EngineFactory.swift:33-72`): parse config → resolve the model URL → `PreparedModel.prepare`
(which is where §4.2's compute-unit decision already happened) → resolve the variant → instantiate.

**Auto-detection is two lines** (✅ `:141-155`):

```swift illustrative
private static func autoDetectVariant(structure: ModelStructure) -> Variant {
    switch structure {
    case .chunkedStatic:
        return .staticShape
    case .dynamic:
        return .pipelined
    default:
        // EngineFactory drives LLM engines only
        preconditionFailure(
            "EngineFactory only supports chunkedStatic and dynamic model structures."
        )
    }
}
```

Three consequences, and the middle one is the most important sentence in this guide.

1. `nil`, `"auto"` and `"default"` all mean auto-detect (`:107-111`). `llm-runner`'s default is the
   string `"default"`.
2. **A macOS dynamic export auto-selects the pipelined GPU engine — which cannot produce logits —
   so `@Generable` guided generation is off by default on the macOS path.** An iOS chunked-static
   export auto-selects `StaticShapeEngine`, which *can* (`supportsLogits: true`,
   ✅ `CoreAIStaticShapeEngine.swift:15`). The nuance matters: this is not "Core AI can't do
   structured output," it is "**the GPU path** can't."
3. ⚠️ **`autoDetectVariant` calls `preconditionFailure` — it crashes, it does not throw.** Hand
   `EngineFactory` a segmenter asset (`.multiFunctionSegmenter`) and your process dies. The
   *override* path throws a clean `unsupportedEngineVariant`; the *auto* path traps. Validate
   `bundle.kind == .llm || .vlm` before you get here.

Explicit overrides are validated against the structure (✅ `:158-176`):

| variant × structure | result |
|---|---|
| `static-shape` × `.dynamic` | ❌ *"Static-shape variant requires chunked static model (extend_* functions)"* |
| `coreai-pipelined` × `.chunkedStatic` | ❌ *"Core AI pipelined variant requires dynamic model"* |
| `coreai-sequential` × `.chunkedStatic` | ❌ *"Sequential variant requires dynamic model"* |
| anything × `.dynamic` or `.chunkedStatic` | ✅ |
| anything × anything else | ❌ *"LLM engine variants are incompatible with this model structure"* |

An unknown string throws with the valid set spelled out (`:116-119`):
`"Unknown variant 'x'. Valid: auto, coreai-sequential, coreai-pipelined, static-shape"`.

**So the only real choice you have is `coreai-pipelined` vs `coreai-sequential` on a dynamic
(macOS-recipe) model.** Chunked-static models have exactly one compatible engine. That single choice
is the subject of the rest of this section.

### 5.3 `CoreAISequentialEngine` — dynamic, CPU-side sampling, logits available

The model contract, ✅ VERIFIED verbatim from the doc comment
(`CoreAISequentialEngine.swift:22-32`):

```
/// Clean Core AI inference engine built from scratch using only public APIs.
///
/// ## Model Contract
///
/// Expects a `.aimodel` with:
/// - **2 inputs**: `input_ids` (Int32), `position_ids` (Int32)
/// - **1 output**: `logits` (LogitsScalarType)
/// - **2 states**: `keyCache`, `valueCache` — persistent across steps, updated in-place
///
/// KV cache NDArrays start small (256 tokens) and grow dynamically with 2× expansion.
/// Passed as `states` on every forward pass; the model graph updates them in-place.
```

`public var supportsLogits: Bool { true }` (`:36`).

⚠️ **Names are taken positionally from the descriptor, not matched by string.** The init validates
`inputNames.count == 2`, `outputNames.count >= 1`, `stateNames.count == 2`, and that the logits
scalar type is `.float16` (else `unsupportedLogitsType`) — then binds `inputs[0]` as `input_ids`,
`inputs[1]` as `position_ids`, `states[0]` as key, `states[1]` as value, `outputs[0]` as logits. So
**a graph that declares its inputs in the other order will load, run, and produce garbage.** If you
author your own model, the input declaration order in `torch.export` is a wire-format decision.

The execution core is the plainest possible use of the Core AI runtime, and it is worth reading if
you want to understand what the pipelined engine is optimising away:

```swift prelude:guide-context
var states = InferenceFunction.MutableViews()
states.insert(&keyCache, for: keyCacheName)
states.insert(&valueCache, for: valueCacheName)

var outputViews = InferenceFunction.MutableViews()
outputViews.insert(&logitsArray, for: logitsName)

_ = try await function.run(
    inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
    states: consume states,
    outputViews: consume outputViews)
```

✅ VERIFIED, `CoreAISequentialEngine.swift`. Note `consume` — `MutableViews` is non-copyable, and
this is Swift 6 ownership doing real work. Note also that outputs are **pre-allocated and reused**
across steps, which is the opposite of the segmenter's style (which pulls outputs out of the return
dictionary). Both are valid Core AI usage; this one avoids a per-step allocation. The source
comment puts the saving at *"~50–100 µs/step"* for caching `input_ids` / `logits` NDArrays and only
reallocating on a batch-size change.

Prefill strategy: `.chunked(chunkSize: config.prefillChunkSize)` when
`newTokenCount > config.chunkThreshold`, else `.wholeBatch`. Defaults are 512 and 1024 (§5.7).

### 5.4 `CoreAIPipelinedEngine` — GPU, on-device sampling, **no logits**

The feature list, ✅ VERIFIED verbatim from the file header (`CoreAIPipelinedEngine.swift:36-43`):

```
/// GPU-pipelined inference engine using Core AI's encode API.
///
/// Key features:
/// - Non-blocking GPU encoding via `InferenceFunction.encode`
/// - GPU-direct token sampling (argmax/topK) via MPSGraph compute shaders
/// - Pipeline-depth-matched buffer rotation for CPU/GPU overlap
/// - Growing KV cache with pipelined expansion
/// - All tensors are owned MTLBuffers — Core AI never allocates/frees them
```

The design is a genuine pipeline: encode step *n+1* onto the GPU while step *n*'s sampler callback is
still running, with `pipelineDepth = 3` and every buffer rotated by that depth. Decode reads its
input token from `decodeOutputBuffers[(step + pipelineDepth - 1) % pipelineDepth]` — **the previous
step's GPU-written token, never round-tripping to the CPU.** That is where the speed comes from, and
it is also, precisely, why there are no logits for you: the logits never leave the GPU.

Reference 03 covers `InferenceFunction.encode(inputs:states:outputViews:to:)`, `ComputeStream`, and
`AsyncMutableViews`. What matters here are the four hard errors:

```swift compile:27
// includeLogits == true
"CoreAI pipelined engine does not support logits (GPU-side sampling). "
    + "Use a sequential engine for constrained generation or evaluation."

// forcedContinuation != nil
"CoreAI pipelined engine does not support forcedContinuation (GPU-side sampling). "
    + "Use a sequential engine for evaluation."
```

✅ VERIFIED verbatim, `CoreAIPipelinedEngine.swift:114-124`. Plus, from `generate()`:

- **Changing temperature or crossing the greedy boundary mid-generation throws** —
  `"Sampling configuration changed mid-generation. Call reset() first."` /
  `"Temperature changed mid-generation (a -> b). Call reset() first."` The reason is structural: the
  MPSGraph sampler is constructed with a fixed vocabulary size and temperature, so *"changing
  temperature requires engine reset + new sampler."*
- **`contextLengthExceeded` is checked before prefill**, when
  `maxContextLength - processedTokenCount - prompt.count < 1`.

Two internals worth knowing because they explain symptoms you will otherwise misdiagnose:

**`PipelineGate` exists because the producer outruns the consumer.** Its doc comment names the
numbers: *"Without this, the decode loop submits encodes (~220/s) faster than the sampler callback
drains them (~70/s); depth grows until `MPSCommandBufferImageCache` fails to allocate another
private MTLBuffer."* It is a class rather than an actor deliberately: `release()` runs synchronously
from the Metal completion callback, and an actor would force `Task { await release() }` with
ordering ambiguity.

**`reset(to:)` behaves differently from the other engines.** Full reset (`tokenIndex == 0`) cancels,
drains, waits for GPU completion, resets and clears history. Partial reset (`tokenIndex > 0`)
**deliberately does not cancel** — *"cancelling corrupts the pipeline's double-buffer state"* — it
drains, waits, then rewinds counters. And a mid-`generate()` divergence forces a **full** reset:
*"Tokens differ — full reset (partial rewind corrupts buffer rotation)."* So on the pipelined engine,
partial rewind is available but fragile, and any prompt divergence throws away the whole cache.

> ⚠️ **SILENT FAILURE (fixed, but instructive) — pipelined sampling used to corrupt text at
> temperature > 0.** Commit `aff0bb2` (#121, 2026-07-23): *"The `MPSGraphCompositeSampler` reused a
> single `MPSGraphExecutableExecutionDescriptor` across all pipelined steps. Under pipelined
> execution (depth > 1), overlapping `runAsync` calls on the same executable corrupt intermediate
> scratch buffers when sharing a descriptor, producing garbled output (word repetitions, doubled
> punctuation) with temperature > 0."* The output was *plausible English*, just subtly wrong — no
> crash, no error, no log line. **If you pinned `coreai-models` before 2026-07-23 and you sample at
> temperature > 0 on the pipelined engine, update.** And take the general lesson: on this path,
> "the text looks a bit repetitive" is a legitimate bug report, not a model-quality observation.

### 5.5 `StaticShapeEngine` — Neural Engine, chunked static, logits available

The engine for iOS exports. `supportsLogits: true` (✅ `CoreAIStaticShapeEngine.swift:15`).

Its I/O contract is by **literal name**, and the source says so in a MARK comment
(✅ `:17-21`):

```swift illustrative
// MARK: I/O name contracts — models must use these exact names

private static let logitsOutputName = "out_logits"
private static let keyCacheName = "key_cache"
private static let valueCacheName = "value_cache"
```

Note the divergence from the sequential engine: `out_logits` not `logits`, `key_cache`/`value_cache`
(snake) not `keyCache`/`valueCache` (camel). **Two engines in one package, two naming conventions,
and no shared constant.** That is the iOS/macOS export split showing through into the runtime, and
it means a graph cannot satisfy both engines.

How it works:

- Function names with prefix **`extend`** or **`prompt`** are decoder functions; `gather_embeddings*`
  are gather functions.
- `maxQueryLength` = the maximum trailing integer across the extend function names (fallback 64).
- It **requires** an extend function whose context length equals `config.maxContextLength`, else
  `invalidState("Failed to find an extend function with the max context length of N")`. So
  `metadata.json`'s `max_context_length` and the exported function names must agree exactly. If you
  hand-edit the metadata to a smaller context "to save memory," this is where it fails.
- The embedding table is loaded **once at init** from `load_embeddings`, and the KV caches are
  allocated from the max-context descriptor, IOSurface-backed.
- `ModelShapeSelector` picks the right `extend_<ctx>_<q>` per step via
  `selectShape(currentSeqLength:desiredQuerySize:)` and
  `selectShapeForDecode(currentSeqLength:tokensToProcess:)`.

The Python side that produces this shape is worth seeing once, because it explains the function-name
explosion (✅ `python/src/coreai_models/export/ios.py`):

```python
query_lengths = [8, 16, 64]
cache_len = 256
while cache_len <= max_context_length:
    for q_len in query_lengths:
        forward_static_cfg[f'"{cache_len}_{q_len}"'] = { … }
    cache_len *= 2
coreai_program.set_static_shape_config(EXTEND_FUNCTION_NAME, forward_static_cfg)
```

A 4096-context iOS export therefore carries `extend_{256,512,1024,2048,4096}_{8,16,64}` — fifteen
specializations of one function, plus the same again for `prompt_opt`, plus three
`gather_embeddings_<q>`. **All of them compile from one dynamic `torch.export`** via Core AI shape
specialization (Apple's own `model-authoring` skill states this: *"All functions compile from one
dynamic `torch.export` via Core AI shape specialization."*).

That is also why cold specialization on the ANE path is expensive — see §5.8's numbers.

### 5.6 `CoreAISequentialVLMEngine`

Conforms to `MultimodalInferenceEngine`, which adds two members to the base protocol
(✅ `InferenceEngine.swift:301-315`):

```swift prelude:guide-context
public protocol MultimodalInferenceEngine: InferenceEngine {
    func encodeImage(at url: URL) async throws -> EmbeddedInput
    func generate(with input: EmbeddedInput,
                  tokens: [TokenId],
                  samplingConfiguration: SamplingConfiguration,
                  inferenceOptions: InferenceOptions) async throws -> OutputSequence
}
```

and the protocol's own doc comment states the flow and, crucially, who owns the cache:

> *"1. `encodeImage(at:)` — preprocess + run vision encoder, return embeddings. 2.
> `generate(with: EmbeddedInput, …)` — scatter-merge embeddings into token sequence and run prefill
> + decode. **The caller owns the embeddings and decides caching strategy.**"*

```swift compile:27 imports:CoreAI
public struct EmbeddedInput: Sendable {
    public let embeddings: NDArray          // [batch, seq_len, hidden_dim]; init throws if rank != 3
    public let embeddingPositions: Range<Int>
    public var tokenCount: Int { embeddings.shape[1] }
}
```

`supportsLogits: true` (✅ `CoreAISequentialVLMEngine.swift:77`) — so guided generation works on the
VLM path.

⚠️ **VLM sampling is hard-coded.** `CoreAIVisionLanguageModel` uses
`SamplingConfiguration(temperature: 1.0, topK: 1)` — effectively greedy — with `maxTokens` defaulting
to 512, and its stop set is the tokenizer EOS plus `<|im_end|>`. The `GenerationOptions.temperature`
you pass through Foundation Models does not reach it. There is also a `TODO` in the protocol file
about multi-turn image caching: *"caller can cache `EmbeddedInput` across turns and pass it again with
the accumulated token context."* That is a note-to-self, not an implemented feature.

### 5.7 KV cache strategy — and the memory arithmetic behind it

✅ VERIFIED verbatim, `InferenceEngine.swift:327-367`:

```swift compile:27
public enum KVCacheStrategy: String, Codable, Sendable, CaseIterable {
    case auto      = "auto"
    case fixedSize = "fixed_size"
    case growing   = "growing"
    case chunked   = "chunked"

    public func defaultSize(maxContextLength: Int) -> Int? {
        switch self {
        case .auto:      return nil   // Resolved at factory level based on model capability
        case .fixedSize: return maxContextLength
        case .growing:   return 256
        case .chunked:   return maxContextLength
        }
    }
}
```

Documented semantics, from the same enum's comments:

| Case | Behaviour | Cost |
|---|---|---|
| `.auto` | `growing` if the key-cache seq dim is dynamic (`-1`), else `fixedSize` | — |
| `.growing` | start at 256, grow 2× up to `maxContextLength`, copying on growth | *"~20 ms stall on growth (amortized O(log₂ N))"* |
| `.fixedSize` | allocate `maxContextLength` up front | ⚠️ multi-GB on long-context models, **and slower every step** |
| `.chunked` | *"Fixed size with sliding window (**not yet implemented**)"* | — |

> ⚠️ **`.chunked` is accepted and silently falls back.** The enum case exists, the CLI accepts
> `--kv-cache-strategy chunked`, `defaultSize` returns `maxContextLength` for it, and the doc comment
> says "not yet implemented." You get a fixed-size cache with no error and no warning. **Do not
> select it.** If you need bounded memory for an unbounded conversation, implement the window in
> your caller by trimming the transcript, not by asking the engine.

Apple's own warning about `.fixedSize`, verbatim (`EngineFactory.swift:245-247`):

> *"Avoid `.fixedSize` unless you need a known upper bound. It pre-allocates the cache at the full
> `maxContextLength`, which can consume several gigabytes on long-context models and slows each
> decoding step because every iteration operates on the full-size KV."*

The second clause is the one people miss. A fixed-size cache is not just memory — **every decode step
attends over the full allocation**, so a 262 144-token `qwen3-coder-30b-a3b` preset with
`.fixedSize` is slow from token one.

Explicitly selecting a non-auto, non-`fixedSize` strategy on a static-seq-dim model throws:

> `"Strategy 'growing' requires dynamic KV cache support. Model has fixed seqDim. Re-export with --dynamic-sized-kvcache-gpu flag."`

> 🔴 **GAP — `--dynamic-sized-kvcache-gpu` does not exist.** That flag appears in Swift error strings
> and in `KVCacheStrategy.auto`'s doc comment, and **there is no such flag in any of this repo's
> Python export CLIs** (`coreai.llm.export`, `coreai.vlm.export`, `coreai.diffusion.export` — full
> flag lists checked). It presumably belongs to an internal or superseded exporter. **Safe default:
> ignore the suggestion and use `.auto`.** The macOS recipe already produces dynamic KV caches; the
> iOS recipe deliberately does not, and no flag changes that. Resolving this needs either a newer
> `coreai-torch` release or an Apple statement.

And the capacity error, which is at least actionable:

> `"KV cache capacity exceeded: need N tokens but only M available. Use --kv-cache-strategy growing for automatic expansion."`

**The related dial is prefill chunking**, and Apple documents its arithmetic in the protocol
extension (✅ verbatim, `InferenceEngine.swift:163-178`):

```
/// Default prefill chunk size: 512 tokens.
///
/// Trade-off: smaller = less memory but more overhead.
///
/// ## Memory Calculation
/// Logits buffer = batch × seqLen × vocabSize × sizeof(Float16)
///
/// Example with Qwen3 (vocab_size = 151,936):
/// - 32K prompt without chunking: 1 × 32,768 × 151,936 × 2 = **9.6 GB**
/// - 512-token chunk:             1 × 512 × 151,936 × 2 = **155 MB** (98% reduction)
```

Apple-published (source comment, no hardware attached — it is arithmetic, not a measurement). That
9.6 GB is why `chunkThreshold` defaults to 1024 and `prefillChunkSize` to 512, and why
`COREAI_CHUNK_THRESHOLD` is the knob you reach for when prefill OOMs.

Community-measured, and it complicates `llm-runner`'s own help text. The CLI hints *"use 128 for
MoE"*. Measured on **M4 Max 128 GB, macOS 27 beta, gpt-oss-20b, 4096-token prefill, 3 trials**
(community — `john-rocky/coreai-model-zoo` `knowledge/apple-models-bench.md`; **not Apple**):

| `COREAI_CHUNK_THRESHOLD` | Prefill tok/s | Peak dirty footprint |
|---|---:|---:|
| **128** (the MoE hint) | 766 | **1.7 GB** |
| **1024** (default) | 1237 | not measured |
| **8192** (no chunking) | **1439** | **18.0 GB** |

The author's reading: *"the hint is really a **memory dial**. Unchunked MoE prefill allocates huge
expert activations (~18 GB dirty for 4096 tokens on top of the mmap'd weights). On a 16–32 GB Mac
that would swap or jetsam — chunk 128 caps it at 1.7 GB for a 1.9× prefill cost. On a big-RAM Mac,
RAISE the threshold: +16 % prefill over the default for free. Decode is unaffected (~76–78 tok/s
everywhere)."* Repro:

```bash
COREAI_CHUNK_THRESHOLD=8192 swift run -c release llm-benchmark \
    --model exports/gpt_oss_20b_dynamic -p 4096 -g 128 -n 3
```

Treat the numbers as one person's Mac. Treat the *shape* — memory dial, prefill-only, decode
unaffected — as the actionable part.

### 5.8 Choosing an engine: the decision table

| | `coreai-sequential` | `coreai-pipelined` | `static-shape` |
|---|---|---|---|
| Model structure | `.dynamic` | `.dynamic` | `.chunkedStatic` |
| Auto-selected for | never | **`.dynamic` (macOS recipe)** | **`.chunkedStatic` (iOS recipe)** |
| Compute unit | GPU (`.gpu` + `expectFrequentReshapes`) | GPU, same | **Neural Engine** |
| Sampling runs on | CPU (`CompositeSampler`) | GPU (`MPSGraphSampler`) | CPU |
| `supportsLogits` | ✅ **true** | ❌ **false** | ✅ **true** |
| `@Generable` / JSON schema | ✅ | ❌ throws `unsupportedCapability` | ✅ |
| `forcedContinuation` (eval) | ✅ | ❌ throws | ✅ |
| Implicit prefix caching | ✅ (`TokenHistory`) | ✅ (`TokenHistory`) | ✅ (`TokenHistory`) |
| Temperature change mid-gen | fine | ❌ throws | fine |
| I/O names | `input_ids`, `position_ids`, `logits`, `keyCache`, `valueCache` | same | `out_logits`, `key_cache`, `value_cache` |
| Speed | slower | **fastest** | fastest on iOS |

✅ All rows verified against the engine sources cited above.

**The one-line rule:**

> **Pipelined unless you need logits. If you need `@Generable`, evaluation, or a custom sampler,
> pass `variant: "coreai-sequential"` and accept the throughput cost.**

How to say it, three ways:

```swift prelude:guide-context
// 1. Through the Foundation Models adapter:
let model = try await CoreAILanguageModel(resourcesAt: url, variant: "coreai-sequential")

// 2. Through CoreAIRunner:
let engine = try await CoreAIRunner(bundle: bundle, variant: "coreai-sequential")
    .makeInferenceEngine()

// 3. Through EngineFactory, if you are holding the config bytes yourself:
let engine = try await EngineFactory.createEngine(
    config: bundle.rawMetadata,
    modelURL: bundle.requireModelURL(for: ModelBundle.ComponentKey.main),
    options: EngineOptions(variant: "coreai-sequential", kvCacheStrategy: .auto))
```

⚠️ Note the variant is a **`String?`, not an enum**, in every public API. `Variant` is `private` to
`EngineFactory`. So `"coreai-sequental"` is a runtime error, not a compile error. Define your own
constants:

```swift compile:27
enum CoreAIEngineVariant {
    static let auto = "auto"
    static let sequential = "coreai-sequential"
    static let pipelined = "coreai-pipelined"
    static let staticShape = "static-shape"
}
```

⚠️ And a documentation trap: `CoreAILanguageModel.init`'s own doc comment says
*"Engine variant override (e.g. `"coreai-sequential"`, `"ane"`)"* (✅ `CoreAILanguageModel.swift:88-89`).
**`"ane"` is not a valid variant.** `Variant(rawValue: "ane")` returns `nil` and you get
`"Unknown variant 'ane'. Valid: auto, coreai-sequential, coreai-pipelined, static-shape"`. The
Neural Engine spelling is `"static-shape"`, and you cannot pick it on a dynamic model anyway.

### 5.9 What the engines actually measure

Every number in this subsection is **community-measured** by one author on his own hardware, using
**Apple's own recipes, unmodified, and Apple's own `llm-benchmark` runner**. It is not Apple-published
and Apple publishes nothing comparable. Protocol, stated by the source: **512 prompt / 1024
generation / 5 trials, release build** — the same protocol as `mlx-lm benchmark`, on which
`llm-benchmark` is explicitly modelled.

**macOS, MacBook Pro M4 Max 128 GB, macOS 27 beta** (community — `apple-models-bench.md`):

| Model | Preset | Artifact | Prompt tok/s | Gen tok/s | Load (warm) | Peak RSS |
|---|---|---|---:|---:|---|---|
| qwen3-0.6b | `4bit` fp16 ctx 8192 | 335 MB | 9396 | **484** | 0.10 s (cold 0.85 s) | 0.77 GB |
| qwen3-4b | `4bit` fp16 ctx 40960 | 2.1 GB | 1635 | 145.4 | 0.36 s (cold 1.95 s) | 4.6 GB |
| qwen3-8b | `4bit` fp16 ctx 40960 | 4.3 GB | 912 | 94.1 | 0.64 s (cold 2.92 s) | 9.3 GB |
| gemma3-4b-it | `4bit` bf16 ctx 131072 | 2.1 GB | 1669 | 141.5 | 0.32 s (cold 2.20 s) | 4.5 GB |
| gemma3-12b-it | `4bit` bf16 ctx 131072 | 6.2 GB | 578 | 55.0 | 5.4–7.7 s (variance) | 13.4 GB |
| mistral-7b-v0.3 | `4bit` fp16 ctx 8192 | 3.8 GB | 976 | 101.7 | 0.56 s (cold 2.49 s) | 8.3 GB |
| gpt-oss-20b (MoE) | `none` bf16, MXFP4 kept | 13 GB | 1252 | 78.1 | 2.1 s (cold 13.2 s) | 33.9 GB |

All on the **pipelined** engine (auto-selected for `.dynamic`).

Three caveats the same source attaches to its own numbers, all of which you should carry:

1. **Protocol dominates.** The same artifact measures **115 tok/s at 512p/1024g and ~184 tok/s at
   128p/128g** — a 1.6× swing from measurement protocol alone. A headline tok/s without a stated
   protocol means nothing.
2. **Cold load includes on-device specialization and must be reported separately.** gpt-oss-20b:
   13.2 s cold vs 2.1 s warm.
3. **RSS vs footprint.** `/usr/bin/time -l`'s "peak memory footprint" counts only **dirty** pages;
   the mmap'd weight file shows up in "maximum resident set size." Report RSS for "how much RAM do I
   need," footprint for "how much does inference allocate."

**iPhone 17 Pro, iOS 27 beta** (community, same source and protocol). This is the ANE path, and it
is where the specialization tax gets real:

| Variant | Prompt tok/s | Gen tok/s (run 1 / run 2) | Load cold / warm | Footprint |
|---|---:|---|---|---|
| qwen3-0.6b **ANE** (official iOS preset, mixed 4/8-bit static, ctx 4096) | 5325 | **69.6 / 54.1** | 2.85 s / **0.045 s** | 1.1 GB |
| qwen3-0.6b **GPU** (macOS dynamic recipe compiled for iOS) | 1519 | 57.2 / 52.5 | 1.14 s / 0.07 s | 0.47 GB |
| qwen3-4b **ANE** (official iOS preset) | 546 / 462 | 13.2 / 12.2 | **194 s** / 0.46 s | 3.3 GB |

**194 seconds of cold on-device specialization** for a 3 GB `.aimodelc`. That is the number that
justifies WWDC26 session 326's entire "build a dedicated first-run experience" recommendation
(🟡 spoken narration; the recommendation is Apple's, the number is community). The run-1 → run-2
drop is thermal, not cache state.

The source also notes that **iOS execution requires AOT**: `--platform iOS --preferred-compute <unit>
--architecture h18p`, *"then point `metadata.json` `assets.main` at the `.aimodelc` — an uncompiled
`.aimodel` fails at engine load with `NSPOSIXErrorDomain Code=2`."* That is §2.10 with a specific
error code attached. Attribute as community-measured; the requirement to hand-edit metadata is
✅ verified in Apple's own README.

> ⚠️ **One community finding worth flagging because it will confuse you if you hit it.** The same
> author measured the *same recipe, same code, same wheels* producing a **2.2× faster artifact when
> exported on macOS 26 than on the macOS 27 beta** (mechanism identified as loss of native
> quantized-Linear lowering in favour of explicit dequant ops), on the identical device. If that
> holds, it is a beta-toolchain regression, and it means **"an `.aimodel` is a build artifact, not a
> pure function of the recipe."** Community-measured, single-source, beta-era, and it may well be
> fixed by the time you read this. The durable advice regardless: **version-stamp your artifacts and
> keep them.** Record the exporting machine's OS build and the `coreai-core` / `coreai-torch` /
> `coreai-opt` versions in `metadata.json`'s `user_data` block (§2.2) — that is what it is for.

---

## 6. KV cache strategy and prefix reuse

Reference 03 covers states as a mechanism. This section covers the thing you actually care about:
**turn 2 of a conversation should not re-read turn 1.**

### 6.1 What Apple's engines already do for you

All three LLM engines carry a `TokenHistory` and use it for **implicit prefix caching**. The type is
40 lines and its doc comment is the clearest statement of the idea anywhere in the repo
(✅ VERIFIED verbatim, `InferenceEngines/TokenHistory.swift:8-22`):

> *"Tracks processed token history for implicit prefix caching. Used by inference engines to resolve
> full-context input into only the new tokens that need processing, enabling automatic KV cache reuse
> across multi-turn conversations **without caller intervention**.*
>
> *When a caller passes full context (prompt + previous output + new suffix) to `generate(with:)`, the
> engine calls `resolve(input:)` to find the longest common prefix between the input and the cached
> history. Only tokens beyond that prefix need to be processed; the KV cache already contains the
> prefix's representations.*
>
> *If the input diverges from history (e.g., "Alpha beta" → "Alpha romeo"), the engine rewinds its KV
> cache to the divergence point and reprocesses from there."*

```swift illustrative
func resolve(input: [Int32]) -> (commonPrefix: Int, newTokens: ArraySlice<Int32>)
```

It `memcmp`s the whole overlap first and only falls back to an element-wise scan on mismatch
(`:35-55`) — so the common case (full match) is one library call.

The sequential engine's use of it, ✅ VERIFIED verbatim (`CoreAISequentialEngine.swift:358-370`):

```swift prelude:guide-context
// Implicit prefix caching: resolve input against history.
if history.count > 0 {
    let (commonPrefix, _) = history.resolve(input: input)
    if commonPrefix < input.count && commonPrefix < history.count {
        // Divergence: input differs from history. Full reset needed.
        internalReset(to: 0)
    } else if processedTokenCount >= input.count {
        // Pure extension: all input tokens match history. Rewind for seeding.
        let resetTo = Swift.max(0, commonPrefix - 1)
        internalReset(to: resetTo)
    }
    lastPrefixHitCount = commonPrefix
}
```

Three things to take from that:

1. **You get prefix reuse for free if — and only if — you hand `generate(with:)` the full running
   token sequence every turn.** The engine does the diffing. Hand it just the new user turn and it
   sees a divergence at token 0 and throws the cache away.
2. **Divergence costs you everything.** There is no partial-rewind-on-divergence in the upstream
   sequential engine: `internalReset(to: 0)`. Whether that is optimal is arguable — the *information*
   for a partial rewind is right there in `commonPrefix` — but it is what ships.
3. **`lastPrefixHitCount` is your instrumentation.** Read it after every `generate()` and log it.
   If it is not growing across turns, your prompt renderer is not byte-stable (see §6.4).

`reset(to:)` is the exposed primitive:

```swift illustrative
/// Reset KV cache to the state after processing `tokenIndex` tokens.
/// - tokenIndex == 0: full reset (clear all state, equivalent to reset())
/// - tokenIndex > 0: partial reset (keep cache for first tokenIndex positions)
/// Precondition: tokenIndex >= 0 && tokenIndex <= processedTokenCount
func reset(to tokenIndex: Int) async throws
```

The repo's own test suite asserts the property that makes this trustworthy:
`UnifiedGenerationAPITests` contains *"reset(to:) produces identical output vs full re-generate — 20
random iterations"* (✅ test name, `swift/Tests/LanguageModelsTests/UnifiedGenerationAPITests.swift`).
That is the losslessness claim, tested.

### 6.2 Why partial rewind is free

The mechanism is worth internalising because it explains both the win and the one case where it is
impossible.

**Nothing is cleared.** A partial rewind is a single integer assignment: `processedTokenCount =
retained`. The KV tensors are left byte-for-byte untouched. Rows at or beyond the retained position
are stale garbage — and they are **overwritten before any causal read can see them**, because a query
at position *p* only attends to keys at positions ≤ *p*, and every position ≥ `retained` gets
rewritten by the next prefill before a query reaches it.

Apple's own `reset()` comment states the invariant: *"the KV pair needs no clearing — attention only
reads positions below the new offset."*

Contrast that with the **full** reset, which *does* zero the caches — and which is why the
`zeroFill` performance bug in §3.4 mattered so much. Full reset is O(cache); partial rewind is O(1).

### 6.3 `trimKVCache` — the community primitive Apple's protocol lacks

Apple's `InferenceEngine` has `reset(to:)` but **no way to ask an engine "how far can you actually
rewind, and what should I feed you afterwards?"** Those two questions have non-obvious answers, and a
community fork added them.

> ⚠️ **Attribution.** Everything in §6.3 and §6.4 is **community work**, not Apple's:
> `john-rocky/coreai-models`, commit **`0fdf710` "InferenceEngine: trimKVCache primitive for
> cross-turn prefix reuse"** (2026-07-03), **3 files, +69/−0**. The fork is a *snapshot* of
> `apple/coreai-models` from before Apple shipped SAM 3, VLM and Speech, plus three commits — so its
> `InferenceEngine` differs from upstream in unrelated ways (its `generate` is not `async`, for one).
> Do not paste the fork's protocol into an upstream checkout. Read it for the **idea**, which
> transfers cleanly.

Two additions to the protocol (✅ VERIFIED verbatim from the fork,
`swift/Sources/CoreAILanguageModels/InferenceEngines/InferenceEngine.swift:111-138`):

```swift illustrative
/// Rewind the KV cache toward `length` tokens for cross-call PREFIX REUSE, keeping the
/// leading cached tokens valid and dropping everything after — so the next
/// `generate(with:)` prefills only the un-cached suffix instead of the whole prompt.
/// (Attention is causal: positions ≥ the retained length are overwritten before being
/// read, so no clearing is needed.)
///
/// Returns the ACTUAL retained prefix length (0…`length`), which may be less than
/// requested because the last generated token's KV can lag one step behind — the
/// caller must prefill from the returned offset, not from `length`. Returns a
/// negative value if the engine can't safely rewind (recurrent/SSM state can't be
/// reconstructed mid-sequence; non-KV engines have nothing to trim), in which case
/// the caller must `reset()` and re-feed the full prompt. Default: unsupported.
func trimKVCache(to length: Int) async -> Int

/// Feed contract for prefix reuse after `trimKVCache`. `true`: `generate(with:)` takes
/// the FULL running sequence and prefills only `input[retained...]` (sequential engine
/// slices internally). `false`: the caller passes ONLY the un-cached suffix (pipelined
/// prefills the given tokens at the current offset). Default: `true`.
var prefixReuseFeedsFullSequence: Bool { get }
```

with fail-safe defaults (`:185-188`):

```swift illustrative
public func trimKVCache(to length: Int) async -> Int { -1 }
public var prefixReuseFeedsFullSequence: Bool { true }
```

Three design decisions in there are worth stealing wholesale, whatever runtime you are on.

**1. Return the *actual* retained length, not a Bool.** *"which may be less than requested because
the last generated token's KV can lag one step behind — the caller must prefill from the returned
offset, not from `length`."* This is exactly the class of off-by-one that produces a subtly wrong
answer rather than a crash: prefill from your requested offset instead of the returned one and you
skip a token's worth of attention, silently.

**2. Make the feed contract explicit and per-engine.** Whether you pass the full sequence or only the
suffix is *not* a property of prefix reuse, it is a property of the engine — and getting it wrong is
another silent-wrong-answer. The sequential engine slices internally
(`prefixReuseFeedsFullSequence == true`); the pipelined engine prefills exactly the tokens it is
handed, at the current offset (`false`).

**3. Negative means "can't," and the default is negative.** Opt-in, fail-safe: an engine that has not
implemented it reports unsupported, and the caller degrades to the old full-re-prefill path. No
existing engine changes behaviour.

The sequential implementation is five lines (✅ verbatim, fork
`CoreAISequentialEngine.swift:437-443`):

```swift prelude:guide-context
public func trimKVCache(to length: Int) async -> Int {
    drain()
    guard length >= 0 else { return -1 }
    let retained = min(length, processedTokenCount)
    processedTokenCount = retained
    return retained
}
```

`drain()` first, so no in-flight generation is still writing KV. Then clamp and assign. Its doc
comment: *"KV-only (no recurrent state) — always safe; no clearing needed since causal attention
never reads positions ≥ the retained offset before they're rewritten."*

### 6.4 The negative result that changes model selection

The pipelined implementation carries one guard, and it is the most interesting line in the patch:

```swift illustrative
mutating func trimKVCache(to length: Int) -> Int {
    guard extraStates.isEmpty else { return -1 }
    let retained = max(0, min(length, processedTokenCount))
    processedTokenCount = retained
    step = retained
    lastSampledToken = nil
    return retained
}
```

with the reason spelled out above it (fork `CoreAIPipelinedEngine.swift:1401-1405`):

> *"Rejected when the graph carries recurrent `extraStates` (GDN/SSM): those hold a running scan that
> can't be reconstructed at position `length` from the retained KV, so a partial rewind would corrupt
> them. Pure attention KV needs no clearing (causal reads never see positions ≥ `length`)."*

**This is the deep asymmetry between attention and linear/recurrent attention on device.** An
attention KV cache is *positionally addressed*: row *i* is self-contained, so you can truncate at any
*i*. An SSM / GatedDeltaNet / Mamba2 state is a **running scan** — one fixed-size tensor that is a
lossy fold of every token seen so far. There is no row to drop. To get the state as of token *k* you
must re-run the scan from 0.

Therefore: **linear-attention and hybrid models forfeit cheap prefix reuse and must re-prefill every
turn.** Named in the source: Qwen3.5 / Qwen3.6 (GatedDeltaNet), LFM2.5, Granite 4 (Mamba2).

That inverts the usual on-device story. Linear attention buys O(1) decode memory and pays for it by
giving up the thing that dominates multi-turn time-to-first-token. On a device where TTFT is the
user-felt metric, **a hybrid architecture can be the wrong choice for a chat app even though it is
the right choice for a single-shot summarizer.** Community-derived from one implementation, not an
Apple claim — but the mechanism is architectural, not implementation-specific, so it will hold
wherever you find it.

(Sidebar, same source: upstream `CoreAIPipelinedEngine` **rejects hybrid bundles outright** —
*"validates exactly two model states (the KV cache pair) … Qwen3.5/3.6 (GatedDeltaNet), LFM2.5, and
Granite 4 (Mamba2) fail at load with `Expected 2 states, got 4`."* The fork relaxes the guard to
`>= 2` plus a bounded extra-state pool whose shapes must be **fully static**. So on stock
`apple/coreai-models` at commit `5ed9981`, the question of prefix reuse on a hybrid does not arise:
the model does not load on the GPU engine at all.)

### 6.5 The caller-side algorithm

If you write a chat loop over these engines, this is the shape. Community-derived
(`knowledge/prefix-cache-kv-reuse.md:40-46`), adapted here to upstream's `async` API. Read it as
pseudocode against upstream, not as a compiling drop-in — `trimKVCache` does not exist upstream, so
step 3 becomes `reset(to:)` plus your own bookkeeping.

```swift prelude:guide-context
// `kvTokens` is the EXACT token sequence the engine's KV currently holds:
// prompt + everything it streamed back. You track this yourself, across turns.
var kvTokens: [Int32] = []

func send(_ userMessage: String) async throws -> String {
    history.append(.user(userMessage))
    let full = try tokenizer.applyChatTemplate(messages: history.messages).map(Int32.init)

    // 1. Longest common prefix, clamped so at least one token is always fed.
    //    Without the clamp the graph has nothing to run.
    let want = min(commonPrefixLength(full, kvTokens), full.count - 1)

    // 2. Ask the engine what it can actually retain. NEVER assume it equals `want`.
    let reused = await engine.trimKVCache(to: want)      // fork API
    let retained: Int
    if reused < 0 {
        try await engine.reset()
        retained = 0
    } else {
        retained = reused
    }

    // 3. Honour the engine's feed contract.
    let feed = engine.prefixReuseFeedsFullSequence ? full : Array(full[retained...])

    // 4. Generate, and BREAK AT THE STOP SEQUENCE — do not drain to maxTokens.
    var out: [Int32] = []
    for try await step in try await engine.generate(
        with: feed,
        samplingConfiguration: .greedy,
        inferenceOptions: InferenceOptions(maxTokens: 512)
    ) {
        if eosTokens.contains(step.tokenId) { break }
        out.append(step.tokenId)
    }

    // 5. The KV now holds `full` + `out`. Record that, exactly.
    kvTokens = full + out
    return tokenizer.decode(tokens: out.map(Int.self.init))
}
```

Step 4's comment is load-bearing and it is why the same fork needed a *second* commit. Prefix reuse is
only correct if the KV ends at a **known** token boundary. Community-reported defect (fork commit
`627fec7`, 2026-06-13): a consumer that `break`s the token stream at EOS leaves the pipelined engine
generating to `maxTokens` **in the background**, and those post-EOS tokens **land in the KV cache**.
The next turn's `reset()`/`drain()` then blocks on the leftover generation. Measured through Apple's
own `CoreAILanguageModel` adapter (qwen3.5-0.8 B, two-turn chat, hardware not stated):
**second-turn latency 2.74 s → 0.40 s** after the fix, same output. Two consequences the source
names: a multi-turn latency tax, and on a slow model, a risk of tripping `drain()`'s `fatalError`
after ~5 s of busy-waiting.

Upstream `apple/coreai-models` has since landed `04a3fd6` "Stop pipelined generation when consumer
drops the stream (#113)" (✅ in the upstream log), which addresses the same class of problem. **If
you are on a checkout older than that, the app-side workaround is to pump the stream through a task
you can settle on the next `respond` rather than breaking the engine's stream directly.**

### 6.6 What it is worth

Community-measured. **qwen3-0.6b, sequential engine, on a Mac — exact model and macOS build not
stated by the source.** Greedy (`temperature 0`), so outputs are comparable byte-for-byte.

| Turn | Prompt tokens | Reused | TTFT reuse ON | TTFT OFF | Speedup |
|---|---:|---:|---:|---:|---:|
| 1 (cold) | 81–3820 | 0 | = OFF | unavoidable | 1× |
| 2 | 357 | 336 | **0.126 s** | **1.915 s** | **15.2×** |
| 2 | 4103 | **4075 (99.3 %)** | **0.230 s** | **23.282 s** | **101×** |

Three turns, greedy: turn 1 cold 826 tokens → 4.40 s; turn 2 reused 826 → **0.122 s**; turn 3 reused
849 → **0.151 s**. Turn 3 reuses turn 2's prompt *and turn 2's answer*.

**Losslessness was checked, not assumed**: with greedy decoding the turn-2 output is **byte-identical**
with reuse on and off.

The scaling shape is the headline and it is the part that generalises: **re-prefill cost grows with
context while reuse cost stays roughly flat.** 15× at 357 tokens, 101× at 4 k, more for real
RAG/agent contexts. And the honest counterweight from the same source: turn 1 still pays full
prefill — 3820 tokens ≈ 22 s on that model's `S=1` sequential prefill — which is a *chunked-prefill*
problem, not something prefix caching addresses.

Where reuse actually lands (`:72-76`): **the system prompt and prior user turns always match**,
because the chat template is append-only there — so the dominant cost in a long RAG or agent context
is always reused. Prior **assistant** turns reuse only when the model's raw generation equals the
template's re-render; thinking-block stripping and retokenization diverge. LCP degrades gracefully:
reuse the common part, re-prefill the tail.

> ⚠️ **Prefix reuse imposes a determinism requirement on your prompt renderer.** This is the
> non-obvious coupling, and it is easy to violate. If your renderer serialises tool-call arguments
> from a dictionary, **sort the keys** — otherwise turn *N*'s re-render of turn *N−1*'s tool call
> differs by one byte, the LCP collapses at that point, and you silently re-prefill everything after
> it. The community `ZooFMProvider` does exactly this: *"The replay path sorts kwargs so re-rendered
> calls are byte-stable (the KV fast path's prefix match depends on it)."* Your symptom will be
> "prefix caching stopped working after I added tools," with no error.

### 6.7 Known limits

From the same community source, so you do not re-derive them:

- **The pipelined `trimKVCache` path is UNVERIFIED.** Implemented and symmetric, but the author could
  not exercise it: their harness forces `variant: "coreai-sequential"` because the pipelined variant
  **SIGTRAPs in `GrowingLogitsBuffer`** for their bundles. Verification needs a multi-turn pipelined
  device harness. 🔴 **GAP.**
- **Short single-turn chats see nothing.** This is a long-context / agent lever only.
- **Two sessions over one engine is a hazard** (§4.3).
- **A "prefill-only" engine call would unlock deeper reuse and does not exist.** Re-anchoring the KV
  to a canonical rendering without sampling would let you reuse assistant turns whose content was
  stripped; `generate()` always decodes, so you cannot. That is a genuine missing primitive in
  `InferenceEngine`, upstream and fork alike.

---

## 7. Grammar-constrained decoding

This is the section that exists nowhere else.

### 7.1 The mechanism

Ask an LLM nicely for JSON and it will *usually* comply. `@Generable` does not rely on usually. Here
is what actually happens when you call
`session.respond(to: prompt, generating: VocabCard.self)` against a Core AI model:

1. Foundation Models turns your `@Generable` type into a **`GenerationSchema`**.
2. The Core AI executor **JSON-encodes that schema** — `try JSONEncoder().encode(schema)` — into a
   JSON Schema string (✅ `CoreAILanguageModel.swift:557`).
3. That string is compiled into a **formal grammar** with a pushdown automaton behind it, by
   **xgrammar**.
4. At **every decode step**, the grammar's current state is turned into a **bitmask over the entire
   vocabulary**: one bit per token, 1 = legal here, 0 = would violate the schema.
5. The mask is applied to the model's **raw logits**, setting every disallowed token to `-infinity`.
6. The sampler samples from the masked logits. `exp(-inf) == 0`, so an illegal token has probability
   exactly zero — **it cannot be emitted**, at any temperature, by any sampling strategy.
7. The chosen token is fed back into the grammar matcher, advancing the automaton.

That is the whole trick, and its consequences are worth stating plainly:

- **Malformed JSON is impossible**, not unlikely. There is no retry loop, no repair pass, no
  "the model usually gets it right."
- **The model's reasoning cannot leak into the output.** A `<think>` block would require emitting `<`
  where the grammar demands `{`, and that token's logit is `-inf`.
- **It costs a vocabulary-sized bitmask fill and a masked pass per token** — for Qwen3, a
  151 936-bit mask, i.e. 4748 `Int32` words.
- **And it requires the logits.** Steps 5 and 6 happen on the CPU, on a `[LogitsScalarType]` array.
  If your engine never surfaces one, none of this can run.

### 7.2 The xgrammar bridge

`apple/coreai-models` wraps xgrammar in three Swift types over a 14-function C bridge. ✅ VERIFIED
verbatim, `GuidedGeneration/XGrammarWrapper.swift`:

```swift prelude:guide-context
public final class CompiledGrammar {
    public let tokenizerInfo: TokenizerInfo
    public var memorySizeBytes: Int          // xgrammar_compiled_grammar_memory_size
}

public final class GrammarCompiler {
    public init(tokenizerInfo: TokenizerInfo, maxThreads: Int = 8, cacheEnabled: Bool = true)
    public func compileJSONSchema(_ schema: String,
                                  anyWhitespace: Bool = true,
                                  strictMode: Bool = true) throws -> CompiledGrammar
}

public final class GrammarMatcher {
    public init(compiledGrammar: CompiledGrammar, maxRollbackTokens: Int = 0)
    public func fillNextTokenBitmask(_ bitmask: UnsafeMutablePointer<Int32>) -> Bool
    public func acceptToken(_ tokenId: Int32) -> Bool
    public var isTerminated: Bool
    public func reset()
}

public enum XGrammarError: Error, LocalizedError {
    case schemaCompilationFailed(String)
}
```

Two details that will matter if you go near this layer.

**The bitmask crosses the bridge as a DLPack tensor.** ✅ VERIFIED verbatim (`:111-129`):

```swift prelude:guide-context
public func fillNextTokenBitmask(_ bitmask: UnsafeMutablePointer<Int32>) -> Bool {
    let bitmaskSize = (vocabularySize + 31) / 32
    var shape = Int64(bitmaskSize)
    return withUnsafeMutablePointer(to: &shape) { shapePtr in
        var dlTensor = DLTensor(
            data: UnsafeMutableRawPointer(bitmask),
            device: DLDevice(device_type: kDLCPU, device_id: 0),
            ndim: 1,
            dtype: DLDataType(code: UInt8(kDLInt.rawValue), bits: 32, lanes: 1),
            shape: shapePtr, strides: nil, byte_offset: 0)
        return xgrammar_matcher_fill_next_token_bitmask(handle, &dlTensor)
    }
}
```

That is why `swift/Sources/lib/CXGrammar/include/` contains a **`dlpack/` directory** next to
`xgrammar_c_bridge.h` and `module.modulemap` (✅ directory listing). DLPack is a cross-framework
tensor ABI; xgrammar's C++ API speaks it, so the Swift bridge constructs a `DLTensor` describing a
plain CPU `Int32` buffer. `kDLCPU` — it is never a GPU buffer.

**`GrammarCompiler.init` and `GrammarMatcher.init` `preconditionFailure` on a NULL handle.** They
crash, they do not throw. Only `compileJSONSchema` throws. So a malformed *vocabulary* is a trap and
a malformed *schema* is an error.

### 7.3 `ConstrainedGenerationSession` — the type you would actually use

The high-level wrapper, and a rare public `~Copyable` type. ✅ VERIFIED,
`GuidedGeneration/ConstrainedGenerationSession.swift:19-253` at `5ed9981`, **extended at
`49becc6` (2026-07-31) — the three additions are marked below and explained in §7.3.1**:

```swift prelude:guide-context
public struct ConstrainedGenerationSession: ~Copyable {
    public let schema: String
    public let vocabularySize: Int
    public var isTerminated: Bool
    public var compiledGrammarMemoryBytes: Int

    public init(jsonSchema: String, vocabulary: [String],
                vocabType: VocabularyType = .byteLevel, stopTokenIds: [Int32]? = nil) throws
    public init(jsonSchema: String, tokenizerInfo: TokenizerInfo) throws
    public init(jsonSchema: String, tokenizer: any Tokenizer, vocabSize: Int,
                vocabType: VocabularyType = .byteLevel, stopTokenIds: [Int32]? = nil) throws
    public init(schemaPath: String, vocabulary: [String],
                vocabType: VocabularyType = .byteLevel, stopTokenIds: [Int32]? = nil) throws

    public mutating func nextTokenBitmask() -> [Int32]?
    @discardableResult public mutating func applyMask(to logits: inout [Float]) -> Bool
    @discardableResult public mutating func applyMask(to logits: inout [Float16]) -> Bool  // non-x86_64
    @discardableResult public mutating func acceptToken(_ tokenId: Int32) -> Bool
    public mutating func reset()

    // NEW at 49becc6 (2026-07-31) — "Part 1 of 4 for GPU-based constrained sampling (#114)".
    @discardableResult public mutating func rollback(_ numTokens: Int = 1) -> Bool
    public func findJumpForwardString() -> String?

    public enum BitmaskResult: Equatable {
        case terminated     // grammar terminated or all tokens blocked — stop generating
        case unconstrained  // all tokens allowed — no mask needed
        case constrained    // bitmask written — apply it
    }
    public mutating func fillBitmask(into pointer: UnsafeMutablePointer<Int32>) -> BitmaskResult
}

public enum ConstrainedGenerationError: Error, LocalizedError {
    case invalidSchema(String)
    case generationFailed(String)
}
```

`~Copyable` because it owns three C++ handles with `deinit`-based lifetime. It is a value type you
`consume` into whatever holds it — see how `ConstrainedDecodingStrategy` wraps it in a class
(`Prepared`) with `init(session: consuming ConstrainedGenerationSession, …)` to get it into an
`AsyncIterator`.

**Termination is detected two ways** (`:27-40`, `:152-165`), and both are needed:

```swift illustrative
public var isTerminated: Bool {
    matcher.isTerminated || allTokensBlocked
}

public mutating func nextTokenBitmask() -> [Int32]? {
    if isTerminated { return nil }
    let hasConstraints = bitmaskBuffer.withUnsafeMutableBufferPointer { buffer in
        matcher.fillNextTokenBitmask(buffer.baseAddress!)
    }
    // xgrammar may signal completion either by returning false, or by filling
    // an all-zeros bitmask (no tokens allowed). Both indicate the grammar is done.
    if !hasConstraints || bitmaskBuffer.allSatisfy({ $0 == 0 }) {
        allTokensBlocked = true
        return nil
    }
    return bitmaskBuffer
}
```

The masking loop itself is a nice piece of code and worth copying if you implement this elsewhere —
it short-circuits fully-set words (`0xFFFF_FFFF` → `continue`) and fully-clear words (write 32
`-inf`s in a row) rather than testing every bit (`:255-279`).

#### 7.3.1 Three additions at `49becc6` — and what they tell you about where this is going

✅ **VERIFIED — source read 2026-08-02** at `apple/coreai-models` `49becc6`, *"Extend
`ConstrainedGenerationSession` with rollback, jump-forward, and direct bitmask fill (#131)"*,
authored 2026-07-31. The commit message labels itself **"Part 1 of 4 for GPU-based constrained
sampling (#114)"** — so read these three as the first quarter of a larger change, not as a
finished feature.

Each has a matching C-bridge entry point (`XGrammarRollback`, `XGrammarFindJumpForwardString`,
`XGrammarFillNextTokenBitmask`), which is the tell that they are exposures of xgrammar capability
rather than Swift-side inventions — consistent with §7.2's account of the bridge.

**1. `rollback(_:)` — unwind grammar state by N tokens.**

```swift illustrative
/// Rollback the grammar state by N tokens. Returns false if rollback failed
/// (e.g., exceeds maxRollbackTokens budget).
@discardableResult
public mutating func rollback(_ numTokens: Int = 1) -> Bool
```

The budget is a compile-time constant: `static let maxRollbackTokens = 64` (`:20`), passed to the
matcher at construction (`:98`). Two ways to get `false`: a negative argument (guarded at the top),
or exceeding the 64-token budget.

> ⚠️ **`@discardableResult` on a fallible state mutation is a footgun.** `session.rollback(80)`
> compiles silently, returns `false`, and leaves the grammar state **where it was** — so a
> speculative-decoding loop that assumes the rollback happened will then feed tokens into a matcher
> that is out of sync with the caller's own token history, and the corruption surfaces later as a
> grammar violation with no obvious cause. **Check the return value.** This is the same shape as
> the `stopTokenIds` trap in §7.4: an API that accepts the request and declines to honour it.

**2. `findJumpForwardString()` — peek at deterministic continuations.**

```swift illustrative
/// Find the longest deterministic string from the current grammar state.
/// Does not change the matcher state. Returns nil if no jump-forward is possible.
public func findJumpForwardString() -> String?
```

Note it is **non-`mutating`** and explicitly documented as state-preserving, so it is safe to call
speculatively. This is the *jump-forward decoding* optimisation: when the grammar admits exactly
one continuation — the `":"` and `"` between a JSON key and its value, say — you can emit those
characters directly instead of running a forward pass per token. For heavily-structured schemas
that is a large fraction of the output. **Nothing in the corpus previously described this
optimisation as available in Core AI's stack.**

**3. `fillBitmask(into:)` — write the mask into caller memory, and a tri-state result.**

```swift illustrative
/// Fill the bitmask directly into a caller-provided buffer (e.g., a GPU-visible MTLBuffer).
///
/// The caller must ensure the pointer has room for at least `(vocabularySize + 31) / 32`
/// Int32 words.
public mutating func fillBitmask(into pointer: UnsafeMutablePointer<Int32>) -> BitmaskResult
```

This is `nextTokenBitmask()` without the per-token `[Int32]` allocation — the commit message's
stated motive is "avoiding array allocation per token", and the doc comment gives a GPU-visible
`MTLBuffer` as an example destination. The current bridge still wraps the pointer as a **`kDLCPU`
DLTensor** and fills it on the CPU, so an `MTLBuffer` is suitable here only when its contents are
CPU-accessible. The issue title ("GPU-based constrained sampling") describes where the completed
four-part integration is heading: a later GPU sampling stage can consume the populated buffer
without copying the mask through a temporary Swift array.

That matters for **§7.8**, which documents the architectural constraint that guided generation and
the fastest (pipelined) engine are mutually exclusive *because logits are not exposed to the CPU*.
🟡 **This commit is the first visible move toward dissolving that constraint** — the mask is still
filled on the CPU today, but a future GPU sampler could consume it without bringing logits back.
It is one of four parts and no end-to-end GPU sampling path is shipped yet; do not rewrite §7.8's
advice on the strength of it. **Re-read #114 before the next beta.**

⚠️ **The buffer-sizing contract is the caller's**, stated only in a doc comment: at least
`(vocabularySize + 31) / 32` `Int32` words. Undersize it and you get out-of-bounds writes into
whatever follows — with an `UnsafeMutablePointer` there is no bounds check and no error.

The `BitmaskResult` tri-state is worth reading carefully, because two of the three cases mean
"do not apply a mask" for opposite reasons:

| Case | Meaning | What the caller must do |
|---|---|---|
| `.terminated` | grammar is finished, **or** every token is blocked | stop generating |
| `.unconstrained` | every token is allowed | sample **without** a mask — the buffer contents are not meaningful |
| `.constrained` | mask written | apply it |

The implementation returns `.unconstrained` when xgrammar signals no mask is needed, and otherwise
scans the buffer for all-zeros — if nothing is allowed it sets `allTokensBlocked` and returns
`.terminated`. So `.terminated` from this method also **mutates** `isTerminated`, which is why it
is `mutating` while `findJumpForwardString()` is not.

> ✅ **Unit-tested at this commit.** `fillBitmaskIntoPointerMatchesNextTokenBitmask` verifies that
> the pointer-writing method matches `nextTokenBitmask()`, and
> `fillBitmaskReturnsTerminatedWhenDone` verifies the terminal result. The remaining 🔴 **GAP** is
> integration-level: there is still no public caller exercising an `MTLBuffer`, no end-to-end GPU
> sampling path, and no on-device run in this corpus (Core AI is absent from the simulator SDK —
> see Part 1). Treat the API's basic behavior as source-and-test-verified and its GPU/device
> integration as unverified.

### 7.4 ⚠️ SILENT FAILURE — the dead `stopTokenIds` parameter

Look carefully at the initializers above. Three of them accept `stopTokenIds: [Int32]?`, and the doc
comment explains what it is for (✅ verbatim, `:122-124`):

> *"stopTokenIds: Token IDs to treat as stop tokens (e.g., EOS). xgrammar allows these tokens only at
> grammar-terminal states (valid JSON complete), blocking them mid-generation. Pass `nil` to rely on
> xgrammar defaults (not recommended)."*

Now trace it. `init(jsonSchema:vocabulary:vocabType:stopTokenIds:)` (`:57-69`) builds:

```swift prelude:guide-context
let tokenizerInfo = TokenizerInfo(
    vocabulary: vocabulary,
    vocabType: vocabType
)
```

**`stopTokenIds` is not passed.** And `TokenizerInfo`'s only initializer is

```swift illustrative
public init(vocabulary: [String], vocabType: VocabularyType = .raw, addPrefixSpace: Bool = false)
```

— there is no `stopTokenIds` parameter and no other sink for it. The C bridge has **no stop-token
entry point at all**: all 14 declarations in `xgrammar_c_bridge.h` are tokenizer-info create/size/free,
compiler create/compile/free, compiled-grammar size/free, and matcher create/fill/accept/terminated/
reset/free. Nothing about stop tokens.

So: **`ConstrainedGenerationSession` accepts a `stopTokenIds` array, documents it as the mechanism
that prevents EOS mid-object, and silently discards it.** And `ConstrainedDecodingStrategy` dutifully
computes and passes one (✅ `ConstrainedDecodingStrategy.swift:95-108`):

```swift illustrative
let singleTokenStops = stopSequences.sequences.filter { $0.count == 1 }.map { $0[0] }
…
let stopTokenIds: [Int32]? = singleTokenStops.isEmpty ? nil : singleTokenStops

let session = try ConstrainedGenerationSession(
    jsonSchema: jsonSchema, tokenizer: tokenizer, vocabSize: vocabSize,
    stopTokenIds: stopTokenIds)
CLILogger.log(
    "Constrained session created (vocabSize=\(vocabSize), stopTokenIds=\(stopTokenIds ?? []))",
    component: "ConstrainedDecodingStrategy")
```

It even **logs the list it is about to throw away.** At `--verbose` you will see
`stopTokenIds=[151645, 151643]` printed by a code path that does nothing with them. There is no
compiler warning: the parameter is consumed by the initializer's signature, just not by its body.

**What this actually costs you, and how the repo compensates.** Commit `cba2c84` "Fix guided
generation: stop on grammar termination, include `<|endoftext|>` (#117)" is the fallout. Two
defence-in-depth measures, both in that commit:

1. The decoder loop stops on `session.isTerminated` **after accept**, returning `nil` *before*
   emitting the terminal token's decoded text — *"This prevents ANY special token from leaking into
   structured output, regardless of whether it's in the stop sequences list."*
2. `"endoftext"` was added to the tokenizer-config stop-token patterns because *"Qwen3 declares
   `eos_token` as `<|im_end|>` (151645) but xgrammar can also produce `<|endoftext|>` (151643) as a
   valid grammar terminal."*

Read that second one again. **xgrammar was emitting a special token as a valid grammar terminal**,
which is precisely the failure the `stopTokenIds` parameter was supposed to prevent.

**What to do:** nothing, if you use `ConstrainedDecodingStrategy` or the Foundation Models path —
the two compensating measures are in place and the tests
(`GuidedGenerationTests/ConstrainedGenerationSessionTests`, 378 lines, including
`allTokensBlockedTermination`) cover them. **But if you build your own loop on
`ConstrainedGenerationSession`, do not rely on `stopTokenIds`.** Check `isTerminated` after every
`acceptToken`, and drop the terminal token rather than decoding it:

```swift prelude:guide-context
let accepted = session.acceptToken(token)
guard accepted else { break }             // grammar rejected it — stop
if session.isTerminated { break }         // do NOT decode this token into your output
emit(tokenizer.decode(tokens: [Int(token)]))
```

> 🔴 **GAP:** whether upstream xgrammar's C++ `TokenizerInfo` supports stop-token ids and Apple's
> bridge simply does not expose them, or whether the capability does not exist upstream either, is
> **unverified** — resolving it needs a read of `mlc-ai/xgrammar` at revision `4d145cc1…`. Either
> way the Swift-side behaviour is settled: the parameter is inert.

### 7.5 ⚠️ A second, quieter trap: the `vocabType` default mismatch

```swift compile:27
public enum VocabularyType: Sendable { case raw; case byteFallback; case byteLevel }
```

- `TokenizerInfo.init` defaults `vocabType` to **`.raw`**.
- `ConstrainedGenerationSession`'s initializers default it to **`.byteLevel`**.
- `TokenizerInfoCache.getOrCreate` also defaults to **`.byteLevel`**.

✅ VERIFIED across `GuidedGeneration/TokenizerInfo.swift` and `ConstrainedGenerationSession.swift`.

So the path most people take (`init(jsonSchema:tokenizer:vocabSize:)`) gets byte-level semantics,
and the path you take when you want to **cache the tokenizer info across sessions**
(`TokenizerInfo(vocabulary:)` → `init(jsonSchema:tokenizerInfo:)`) silently gets **raw** semantics
unless you pass `.byteLevel` explicitly.

Byte-level vs raw changes how xgrammar interprets the vocabulary strings — GPT-2-style `Ġ`-prefixed
byte-level BPE tokens versus literal strings. Get it wrong and the grammar's notion of "which tokens
spell a `{`" is wrong, which manifests as an over-constrained grammar: `allTokensBlocked` fires
immediately, generation produces nothing, and no error is thrown.

**Always pass `vocabType` explicitly:**

```swift prelude:guide-context
let info = TokenizerInfo(vocabulary: vocab, vocabType: .byteLevel)   // never rely on the default
var session = try ConstrainedGenerationSession(jsonSchema: schema, tokenizerInfo: info)
```

### 7.6 `ConstrainedDecodingStrategy` — the per-step loop

The strategy that ties it together. ✅ VERIFIED, `DecodingStrategies/ConstrainedDecodingStrategy.swift`.
The class comment states the algorithm exactly (`:15-18`):

> *"Uses xgrammar bitmask enforcement to ensure generated text conforms to a JSON schema. Each step:
> (1) run one inference step to get logits, (2) apply the grammar bitmask to zero out tokens that
> would violate the JSON schema, (3) sample from the masked logits, (4) accept the token in the
> grammar matcher to advance the grammar state."*

and here is that loop, verbatim (`:117-146`):

```swift illustrative
fileprivate static func generateOneToken(
    inputTokens: [Int32],
    session: inout ConstrainedGenerationSession,
    inferenceEngine: any InferenceEngine,
    samplingConfiguration: SamplingConfiguration,
    constrainedOptions: InferenceOptions
) async throws -> (Int32?, [LogitsScalarType]?) {
    var rawLogits: [LogitsScalarType]? = nil
    for try await output in try await inferenceEngine.generate(
        with: inputTokens,
        samplingConfiguration: samplingConfiguration,
        inferenceOptions: constrainedOptions
    ) {
        rawLogits = output.logits
        break
    }
    guard let logits = rawLogits else {
        throw ConstrainedGenerationError.generationFailed("No logits returned from engine")
    }

    var maskedLogits = logits
    _ = session.applyMask(to: &maskedLogits)

    let bestToken = CompositeSampler.sample(from: &maskedLogits, config: samplingConfiguration)

    if !session.acceptToken(bestToken) {
        return (nil, nil)
    }
    return (bestToken, logits)
}
```

Four things to notice:

1. **The per-step options are hard-coded**: `InferenceOptions(maxTokens: 1, includeLogits: true)`
   (`:191` in the iterator). One engine step per token, logits every time. This is a **fundamentally
   different execution shape** from unconstrained generation, where the engine streams a whole
   sequence. It is also why the pipelined engine cannot participate: `includeLogits: true` throws
   there, immediately.
2. **The engine is reset eagerly**, before the sequence is even returned (`:64`,
   `try await inferenceEngine.reset()`). So starting a constrained generation **discards your KV
   cache**, and therefore all of §6's prefix reuse. Constrained turns are always cold.
3. **`maxTokens` defaults to 512** when `options.maxTokens == nil` (`:62`).
4. **Sampling still applies.** The mask does not force greedy — `CompositeSampler.sample(from:
   &maskedLogits, config:)` honours temperature/topK/topP/minP over the *surviving* tokens. So you
   get schema-valid output that is still varied. `CompositeSampler`'s doc note confirms the design
   works through either sampling path because masked positions are `-inf` and `exp()`s to 0.

**Multi-token stop sequences are dropped, with a warning** (`:96-100`):

```swift prelude:guide-context
if stopSequences.sequences.contains(where: { $0.count > 1 }) {
    CLILogger.log(
        "Warning: Multi-token stop sequences not supported by xgrammar, using single-token stops only",
        component: "ConstrainedDecodingStrategy")
}
```

A `CLILogger` line at verbosity ≥ 1 — i.e. **invisible in an app**, since `CLILogger` prints to
stdout and defaults to level 0. Combined with §7.4, the honest summary is: **on the constrained path,
stop sequences are handled by grammar termination and the EOS-token list, not by your
`StopSequences`.**

**And the vocabulary-size fallback deserves a look** (`:171-193`):

```swift illustrative
static func deriveVocabSize(from tokenizer: any Tokenizer) -> Int? {
    var low = 0
    var high = 524_288
    while low < high {
        let mid = (low + high) / 2
        if tokenizer.convertIdToToken(mid) != nil { low = mid + 1 } else { high = mid }
    }
    if low == 0 {
        CLILogger.log(
            "Warning: Could not determine vocab size from tokenizer — grammar mask may be wrong",
            component: "ConstrainedDecodingStrategy")
        return nil
    }
    return low
}
```

A binary search over `[0, 524288)` for the last valid token id. It assumes `convertIdToToken` is
**monotone** — valid below some threshold, `nil` above. That is true for most tokenizers and false
for any tokenizer with a gap: a binary search across a hole returns the wrong boundary, silently, and
you get a mask sized wrong. **Pass `vocabSize` explicitly.** The Foundation Models path already does
— `ConstrainedDecodingStrategy(jsonSchema: jsonSchema, vocabSize: model.bundle.vocabSize)` — using
the value from `metadata.json`, which is the value the exporter read out of the HF config. That is
the authoritative number and it is right there in your bundle. Use it.

### 7.7 The Foundation Models path — and where the capability check happens

Inside `CoreAIExecutor.respond(to:model:streamingInto:)`, guided generation is one branch. ✅ VERIFIED
verbatim, `CoreAILanguageModel.swift:312-333`:

```swift illustrative
// Check if guided generation is requested
if let schema = request.schema {
    guard engine.supportsLogits else {
        throw LanguageModelError.unsupportedCapability(
            .init(
                capability: .guidedGeneration,
                debugDescription:
                    "This model's inference engine does not support guided generation "
                    + "(constrained decoding requires per-step logits)."
            )
        )
    }
    try await respondConstrained(
        engine: engine, model: model, schema: schema,
        promptTokens: promptTokens, samplingConfig: effectiveSamplingConfig,
        maxTokens: maxTokens, channel: channel)
} else {
    try await respondVanilla(…)
}
```

and `respondConstrained` is the bridge to §7.6 (`:548-576`):

```swift prelude:guide-context
let schemaData = try JSONEncoder().encode(schema)
guard let jsonSchema = String(data: schemaData, encoding: .utf8) else {
    preconditionFailure("GenerationSchema JSON encoding produced invalid UTF-8")
}
let strategy = ConstrainedDecodingStrategy(
    jsonSchema: jsonSchema, vocabSize: model.bundle.vocabSize)
let stopSequences = StopSequences(
    for: model.tokenizer, additionalEosTokenIds: model.additionalEosTokenIds)
let stream = try await strategy.decode(
    from: .tokens(promptTokens), tokenizer: model.tokenizer,
    inferenceEngine: engine, samplingConfiguration: samplingConfig,
    options: InferenceOptions(maxTokens: maxTokens), stopSequences: stopSequences)
```

`GenerationSchema` is `Encodable`, and `JSONEncoder().encode(schema)` produces exactly the JSON
Schema string xgrammar wants. That one line is the whole `@Generable` → grammar bridge.

Note what `respondConstrained` does *not* do: it emits only `.response(action: .appendText(…))`
events, never `.reasoning` and never `.toolCalls` (`:580-596`). So **a constrained turn cannot
produce a tool call or a reasoning entry through this adapter** — which is consistent (the grammar
forbids the markers anyway) but means you cannot mix schema-constrained output with tool use in one
turn.

### 7.8 ⚠️ The architectural constraint: guided generation and the fastest engine are mutually exclusive

Now put §5.2 and §7.7 together.

- `EngineFactory.autoDetectVariant` maps `.dynamic` → `.pipelined`. Every macOS-recipe export is
  `.dynamic`. ✅ VERIFIED.
- `CoreAIPipelinedEngine` has `supportsLogits == false` and throws on `includeLogits: true`.
  ✅ VERIFIED.
- The executor's guard turns that into `LanguageModelError.unsupportedCapability(.guidedGeneration)`.
  ✅ VERIFIED.

**So on the default path, on macOS, with a stock Apple export, `@Generable` does not work.** You get
an error at generation time, on a session you already built, after the model has already loaded.

Community sources reach the same conclusion independently and state the consequence more sharply
than Apple's source does (attribute: `john-rocky/coreai-model-zoo`, `fm-provider.md:84` and
`coreai-vs-mlx-speed.md:124-129`, community-measured on macOS/iOS 27 betas):

> *"FM guided generation (`@Generable`) needs engine logits, and the GPU-pipelined fast path **does
> not expose logits**. MLX exposes logits trivially → structured generation, logprobs tooling, and
> sampler experiments are *easier* on MLX than on Core AI's fast path."*

> *"**GPU-pipelined engines sample on-GPU and return `false`**, so every zoo pipelined bundle lacks
> `.guidedGeneration`; **the sequential engine has it**."*

This is a first-class architectural constraint, not a footnote. An app that brings its own model
**loses Apple's flagship structured-generation feature exactly when it selects the fastest backend.**
Cross-link: Part 1's backend decision table carries this as a column; Part 4 reference 02
(`02-bring-your-own-model.md`) treats it as a selection criterion.

**Now the nuance that most retellings drop.** It is *not* "Core AI can't do guided generation." Three
of the four engines can:

| Engine | `supportsLogits` | `@Generable` | Typical bundle |
|---|---|---|---|
| `CoreAIPipelinedEngine` | ❌ | ❌ | **macOS recipe, auto-selected** |
| `CoreAISequentialEngine` | ✅ | ✅ | macOS recipe, opt-in |
| `StaticShapeEngine` | ✅ | ✅ | **iOS recipe, auto-selected** |
| `CoreAISequentialVLMEngine` | ✅ | ✅ | VLM bundles |

So the accurate statement is: **the GPU-pipelined path is the one that cannot, and it happens to be
the macOS default.** On iPhone, where the ANE static-shape engine is auto-selected, guided generation
works out of the box.

**Your three options, in order of how much they cost:**

**1. Opt into the sequential engine when you need a schema.** One parameter:

```swift prelude:guide-context
let model = try await CoreAILanguageModel(resourcesAt: url, variant: "coreai-sequential")
let session = LanguageModelSession(model: model)
let card = try await session.respond(to: prompt, generating: VocabCard.self)
```

Cost: you give up the pipelined engine's throughput for *all* generation on that model, not just the
constrained turns. On qwen3-0.6b that is the difference between 484 tok/s and materially less
(community-measured decode figures in §5.9 are all pipelined; the sequential engine has no published
comparison — 🔴 **GAP**, and it is a gap worth closing with your own `llm-benchmark` run:
`--inference-engine-variant coreai-sequential` against the same bundle).

**2. Run two models.** Two `CoreAILanguageModel` values over the same bundle URL, differing in
`variant` — which means differing `Configuration`, which means **two `ModelResources` entries and two
engines** (§4.3). Pipelined for chat, sequential for schema-constrained calls. Cost: two resident
engines, two KV caches, roughly two footprints. Community-measured for a comparable two-model setup
(qwen3-0.6b + qwen3-4b, macOS 27 beta, M-series Mac): *"~102 MB with both bundles loaded but
un-touched, rising to ~920 MB `phys_footprint` after the turns run"* — and note `phys_footprint`
excludes clean mmapped weight pages, so total mapped RSS was higher (~2.4 GB+ for those 4-bit
bundles). **Report both numbers, labelled, if jetsam budget matters to you.**

**3. Check the capability instead of assuming it.**

```swift prelude:guide-context
if model.capabilities.contains(.guidedGeneration) {
    let card = try await session.respond(to: prompt, generating: VocabCard.self)
    apply(card.content)
} else {
    // Free-form + your own parser, with a repair path.
    let text = try await session.respond(to: prompt + "\n\nRespond with JSON only.")
    apply(try lenientlyParse(text.content))
}
```

— which brings us to the trap in that very check.

> ⚠️ **SILENT FAILURE — `capabilities` reports `.guidedGeneration` optimistically before the engine
> loads.** ✅ VERIFIED verbatim, `CoreAILanguageModel.swift:174-180`:
>
> ```swift
> /// Whether guided generation is available for this model.
> private var isGuidedGenerationSupported: Bool {
>     if let supportsLogits = resources.loadedEngineSupportsLogits {
>         return supportsLogits
>     }
>     return variant != "coreai-pipelined"
> }
> ```
>
> and `loadedEngineSupportsLogits` is *"`supportsLogits` of the resident engine, or `nil` when nothing
> is loaded. Used only for best-effort capability reporting before a load"*
> (✅ `ModelResources.swift:39-43`).
>
> Now trace the default path. `CoreAILanguageModel(resourcesAt: url)` defaults to **`mode: .lazy`** —
> the engine is *not* loaded. And it defaults to **`variant: nil`**. So
> `loadedEngineSupportsLogits` is `nil`, the fallback runs, `nil != "coreai-pipelined"` is **true**,
> and `capabilities` reports **`.guidedGeneration`** — for a model that will auto-select the
> pipelined engine and throw the moment you pass a schema.
>
> The check is *correct* only if you explicitly wrote `variant: "coreai-pipelined"` (rare — the whole
> point is that it is the default) or if something already forced a load.
>
> **Defence — force the engine to load before you read capabilities:**
> ```swift
> let model = try await CoreAILanguageModel(resourcesAt: url)
> try await model.load()                       // or pass mode: .eager to the initializer
> let canDoSchemas = model.capabilities.contains(.guidedGeneration)   // now trustworthy
> ```
> `mode: .eager` loads the tokenizer and engine concurrently, so it is not even slower in wall-clock
> terms — you were going to pay the load anyway. **Use `.eager` whenever you intend to branch on
> capabilities**, and keep `.lazy` for the case where the model might never be used.
>
> The same hazard applies to `.toolCalling` and `.reasoning`, but benignly: those are derived from
> tokenizer probes (`convertTokenToId("<think>")`, tool-call marker detection) which run at `init`
> and do not depend on the engine.

### 7.9 Convergent evolution: everyone reached for the same library

Here is the part that is documented nowhere — not in a WWDC session, not on a documentation page,
not in a release note.

**`apple/coreai-models` uses xgrammar.** ✅ VERIFIED: `Package.swift:46` declares
`.package(url: "https://github.com/mlc-ai/xgrammar", branch: "main")`; the `CXGrammar` target at
`swift/Sources/lib/CXGrammar` bridges it with `publicHeadersPath: "include"`; `GuidedGeneration/`
holds the three Swift wrappers.

**`ml-explore/mlx-swift-lm` uses xgrammar too, independently.** ✅ VERIFIED from that repo's
`Package.swift:203-228`, which declares two targets:

| Target | Path | Deps |
|---|---|---|
| `MLXCXGrammar` | `Libraries/MLXCXGrammar` | vendored xgrammar C++17 |
| `MLXGuidedGeneration` | `Libraries/MLXGuidedGeneration` | `MLXLMCommon`, `MLXCXGrammar`, `MLX` |

with `MLXGuidedGeneration` described as **"Grammar-constrained generation (JSON Schema or EBNF) for
any MLX model"** and `MLXFoundationModels` — MLX's `LanguageModel` conformance — taking a
*trait-conditional* dependency on it. Note **"or EBNF"**: MLX exposes the raw grammar surface, where
Apple's Core AI wrapper exposes only `compileJSONSchema`. Same engine, wider aperture.

**And there is source-level evidence that the `CoreAI` framework itself ships a third copy.**
`mlx-swift-lm`'s manifest renames the vendored C++ namespaces at compile time, and the comment says
why (✅ VERIFIED verbatim, `mlx-swift-lm/Package.swift:141-146`):

```swift illustrative
// Rename the vendored C++ namespaces at compile time so this
// target's symbols cannot collide with another xgrammar in the
// same binary (e.g. CoreAI's prebuilt copy). …
.define("xgrammar", to: "mlx_xgrammar"),
.define("picojson", to: "mlx_picojson"),
```

*"e.g. CoreAI's prebuilt copy."* Somebody at MLX hit, or anticipated, a duplicate-symbol collision
against Core AI in the same binary. That is as close to a specification of Apple's on-device guided
generation implementation as anything public.

`mlx-swift-lm` pins xgrammar to a **release tag** rather than a branch — `v0.1.30` (resolved SHA
`d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505`), synced by `scripts/sync-xgrammar-source.sh` — which is
the more defensible choice of the two (§3.2).

**Three independent implementations, one library.** Draw the conclusions:

1. **This is how `@Generable` is enforced on non-Apple models, everywhere.** Not prompt engineering,
   not retry loops, not JSON repair. Grammar-constrained logit masking. If you are authoring a
   `LanguageModel` conformance for your own runtime (Part 4 reference 03) and you want to declare
   `.guidedGeneration`, this is the implementation you are expected to provide.
2. **If you link both `CoreAILM` and MLX's guided generation in one app, mind the symbols.** MLX has
   already defended its side; Core AI's `CXGrammar` target has not. Two unrenamed xgrammars in one
   binary is a duplicate-symbol link error at best and a silently-chosen-wrong-implementation at
   worst.
3. **The C++ dependency is not optional.** Both packages carry `cxxLanguageStandard: .cxx17` and
   `.linkedLibrary("c++")`. If your app has a policy against C++ interop, guided generation on a
   BYO model is not available to you today.

> 🔴 **GAP — is `SystemLanguageModel`'s guided generation the same mechanism?** The evidence above
> shows that *some* CoreAI binary ships xgrammar, and that Apple's public Core AI Swift package uses
> it. Whether Apple's *built-in* on-device model constrains through the same code path, or through a
> private mechanism inside the model server, is **unverified** — the observable difference (Apple's
> model does structured output on a path where you never see logits) is consistent with either.
> **Safe default: reason about your own models with the mechanism in this section, and treat
> `SystemLanguageModel`'s structured output as a black box that happens to be reliable.** Resolving
> this needs framework-level symbol inspection.

### 7.10 A complete, self-contained constrained-generation loop

Everything above, assembled. This is the "I do not want Foundation Models, I want the grammar"
version — useful when you are building a classifier, a router, or an eval harness.

```swift prelude:external-module
import CoreAILanguageModels
import CoreAIShared
import Foundation
import Tokenizers

// A schema that only accepts one of three labels.
let schema = """
{
  "type": "object",
  "properties": {
    "intent": { "type": "string", "enum": ["search", "create", "delete"] },
    "confident": { "type": "boolean" }
  },
  "required": ["intent", "confident"],
  "additionalProperties": false
}
"""

let bundleURL = URL(fileURLWithPath: "exports/qwen3_0_6b_4bit_dynamic")
let bundle = try LanguageBundle(at: bundleURL)
try bundle.bundle.verify()

// The sequential engine, explicitly. The default (pipelined) cannot do this.
let engine = try await CoreAIRunner(bundle: bundle, variant: "coreai-sequential")
    .makeInferenceEngine()
guard engine.supportsLogits else {
    fatalError("engine cannot produce logits — constrained decoding is impossible")
}
let tokenizer = try await bundle.loadTokenizer()

// Grammar session. Pass vocabSize from metadata — never let it binary-search (§7.6).
var session = try ConstrainedGenerationSession(
    jsonSchema: schema,
    tokenizer: tokenizer,
    vocabSize: bundle.vocabSize,
    vocabType: .byteLevel                     // explicit; the default differs per initializer (§7.5)
)
print("grammar compiled: \(session.compiledGrammarMemoryBytes) bytes")

// Prompt.
let messages: [[String: String]] = [
    ["role": "user", "content": "Classify this request: 'find my receipts from March'"]
]
let promptTokens = try tokenizer.applyChatTemplate(messages: messages).map(Int32.init)

// One engine step per token, logits every time.
let stepOptions = InferenceOptions(maxTokens: 1, includeLogits: true)
let sampling = SamplingConfiguration.greedy

try await engine.reset()

var input = promptTokens
var generated: [Int32] = []

for _ in 0..<256 {
    // 1. one step → logits
    var logits: [LogitsScalarType]? = nil
    for try await output in try await engine.generate(
        with: input, samplingConfiguration: sampling, inferenceOptions: stepOptions
    ) {
        logits = output.logits
        break
    }
    guard var masked = logits else {
        throw ConstrainedGenerationError.generationFailed("no logits")
    }

    // 2. mask — disallowed tokens become -inf (or -Float16.greatestFiniteMagnitude)
    guard session.applyMask(to: &masked) else { break }   // false ⇒ grammar terminated

    // 3. sample from the surviving tokens
    let token = CompositeSampler.sample(from: &masked, config: sampling)

    // 4. advance the grammar
    guard session.acceptToken(token) else { break }       // rejected ⇒ stop
    if session.isTerminated { break }                     // do NOT emit the terminal token (§7.4)

    generated.append(token)
    input.append(token)                                   // full running sequence; engine slices
}

let json = tokenizer.decode(tokens: generated.map(Int.init))
print(json)     // e.g. {"intent": "search", "confident": true}

// Reuse the same compiled grammar for the next classification — reset is cheap,
// recompiling the schema is not.
session.reset()
```

Two things that loop teaches which the prose cannot:

- **`applyMask` returning `false` is the termination signal**, not an error. It means either the
  matcher terminated or every token got blocked, and both mean the JSON is complete.
- **`input.append(token)` then re-passing the whole array** looks wasteful and is not: the sequential
  engine's `TokenHistory` (§6.1) resolves it to a one-token suffix. That is the same mechanism that
  makes multi-turn prefix reuse work, doing its job inside a single generation.

Finally, the CLI equivalent, for when you want to check a schema without writing any of this:

```bash
swift run -c release llm-runner \
    --model exports/qwen3_0_6b_4bit_dynamic \
    --inference-engine-variant coreai-sequential \
    --json-schema '{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}' \
    --prompt "Who wrote Dune?"
```

`--json-schema` accepts an inline string **or a path**. If you forget
`--inference-engine-variant coreai-sequential` on a macOS-recipe bundle, this is where you meet the
logits error for the first time.

---

## 8. Plugging into Foundation Models

WWDC26 session 324 closes its Core AI Models segment with this (✅ VERBATIM transcript, 324:182-186):

> *"It also provides an API for **creating a Core AI Language model, which plugs right in to the
> Foundation Models framework, letting you bring your own custom models and token sampling
> strategies**."*

and session 326 builds an entire app on it (✅ VERBATIM, 326:103-118):

> *"To load, it's just one line. I create a `CoreAILanguageModel`, point it at my model bundle and
> it's ready. One line — asset loading, engine creation, tokenizer setup — all abstracted away for
> you. Notice we're importing **FoundationModels** here. This is the same framework you may already
> be familiar with. … To use it, I create a **`LanguageModelSession`**. This is the same API that
> gives you access to Apple's on-device large language model. The difference is that now you'll pass
> in your own model to use. Same `session.respond(to:)` call, same streaming support, same
> structured output capabilities."*

The narration is accurate. Here is the code, ✅ VERIFIED against `models/qwen3/README.md` and the
`CoreAILanguageModel.swift` doc comment:

```swift prelude:external-module
import FoundationModels
import CoreAILanguageModels

let model = try await CoreAILanguageModel(resourcesAt: modelURL)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "What is quantum computing?")
print(response)
```

### 8.1 The type

✅ VERIFIED, `LanguageModel/CoreAILanguageModel.swift:31-181`:

```swift illustrative
public struct CoreAILanguageModel: LanguageModel {
    public enum LoadMode: Sendable { case lazy; case eager }
    public typealias Executor = CoreAIExecutor

    public init(resourcesAt url: URL,
                mode: LoadMode = .lazy,
                variant: String? = nil,
                kvCacheStrategy: KVCacheStrategy = .auto) async throws

    public var capabilities: LanguageModelCapabilities
    public var executorConfiguration: CoreAIExecutor.Configuration
    public var estimatedSizeOnDiskBytes: Int? { get }
    public func load() async throws
    public func unload()
}
```

Four parameters, three of which you now understand: `mode` (§4.3 — use `.eager` when you branch on
capabilities), `variant` (§5.8 — `"coreai-sequential"` when you need schemas), `kvCacheStrategy`
(§5.7 — leave it `.auto`).

`estimatedSizeOnDiskBytes` walks `assets.main` recursively (§2.3) — it is the number to show in a
"download this feature?" UI. Session 326 puts the SAM 3 + Qwen3-0.6B pair at *"over 1 GB"* added to
app download size and recommends a feature-introduction screen with an explicit opt-in button and
**Background Assets** download, then specialization behind explanatory UI (🟡 spoken narration; the
recommendation is Apple's, the 1 GB is Apple's own stated figure for their demo app).

### 8.2 Capabilities are auto-detected from the tokenizer

✅ VERIFIED verbatim, `:58-65` and `:141-146`:

```swift prelude:guide-context
public var capabilities: LanguageModelCapabilities {
    var caps: [LanguageModelCapabilities.Capability] = []
    if supportsToolCalling { caps.append(.toolCalling) }
    if supportsReasoning { caps.append(.reasoning) }
    if isGuidedGenerationSupported { caps.append(.guidedGeneration) }
    return LanguageModelCapabilities(caps)
}

self.supportsReasoning =
    tokenizer.convertTokenToId("<think>") != nil
    || tokenizer.convertTokenToId("<|reasoning_start|>") != nil
```

> ⚠️ **`LanguageModelCapabilities(_:)` is unlabelled, and the labelled form is deprecated.** Commit
> `5ed9981` — the repo's HEAD, 2026-07-23 — is a two-line change doing nothing but
> `LanguageModelCapabilities(capabilities: caps)` → `LanguageModelCapabilities(caps)` in
> `CoreAILanguageModel.swift:61` and `CoreAIVisionLanguageModel.swift:29`. If you are writing your
> own conformance against a beta SDK and you see a deprecation warning here, that is the fix.

Tool-call detection probes marker pairs in the vocabulary (`detectToolCallMarkers`): first
`("<tool_call>", "</tool_call>")`, then `("<function_calls>", "</function_calls>")`, then a Mistral
special case `("[TOOL_CALLS]", "\n")` with a synthetic close marker — *"JSON array is single-line."*
Reasoning detection is the two-pair probe above, falling back to `("<think>", "</think>")` so the
parser is harmless on models that emit no reasoning markup.

⚠️ The Mistral synthetic close marker is a real limitation: **a multi-line tool-call JSON breaks the
parser**, because the close marker is a newline.

### 8.3 What the adapter forwards, and what it drops

This is the table to keep, because the gaps are not documented anywhere.

| Foundation Models input | Reaches the engine? | Cite |
|---|---|---|
| `request.transcript` | ✅ rendered via the tokenizer's chat template | `makeTokens(from:using:tools:)` |
| `request.enabledToolDefinitions` | ✅ forwarded to `applyChatTemplate(messages:tools:)` | `:283-287` |
| `request.schema` | ✅ → `ConstrainedDecodingStrategy` (§7.7) | `:313` |
| `generationOptions.temperature` | ✅ | `makeSamplingConfig`, `:767-775` |
| `generationOptions.maximumResponseTokens` | ✅ | `:305` |
| **topK / topP / minP** | ❌ **unreachable through Foundation Models** | `makeSamplingConfig` |
| `Transcript.reasoning` entries | ❌ **deliberately skipped on the way in** | `makeTokens` |

`makeSamplingConfig` is three lines and they are the whole story (✅ verbatim, `:767-775`):

```swift illustrative
private func makeSamplingConfig(
    from options: GenerationOptions,
    base: SamplingConfiguration
) -> SamplingConfiguration {
    if let temperature = options.temperature {
        return SamplingConfiguration(temperature: temperature)
    }
    return base
}
```

Note it **replaces** the base configuration rather than modifying it. So if you constructed the model
with a base config carrying `topK: 40` and then a caller passes `GenerationOptions(temperature: 0.7)`,
**your topK is discarded** — you get `SamplingConfiguration(temperature: 0.7)` with everything else
nil. There is no merge. If you want topK/topP/minP, you must use the non-FM path (§9.3).

The default when nothing is set is `.greedy` — `samplingConfig: .greedy` in the `Configuration`
built by `init` (✅ `:104-110`). **Core AI models are deterministic by default through Foundation
Models**, which is not what people assume.

`maxTokens` defaults are asymmetric and sensible: `model.supportsReasoning ? 2048 : 512` (`:304`).

**Reasoning is skipped on input, emitted on output.** `makeTokens` drops `.reasoning` entries with
the comment *"Don't echo the model's prior reasoning back into the prompt"*, while `respondVanilla`
routes live reasoning to `.reasoning(action: .appendText(…))` channel events so it lands as its own
`Transcript.Reasoning` entry. The source explains the sibling placement (✅ `:487-492`):

> *"Reasoning is a sibling of response/tool-calls in the new API (not nested under response) because
> at parse time we don't yet know whether the model will follow the thought block with a response or
> a tool call."*

⚠️ Practical consequence, community-reported and worth designing around: **thinking is invisible in
`response.content`**, so *"a 'hanging' first response is usually the model thinking"*; and a small
`maximumResponseTokens` on a reasoning model can produce **no response at all** — if the cap cuts
generation mid-`<think>`, the turn yields only reasoning events and the session throws "ended without
producing a response."

### 8.4 `prewarm` — implemented, and worth calling

```swift prelude:guide-context
public func prewarm(model: CoreAILanguageModel, transcript: Transcript) {
    Task { try? await resources.loadResources() }
}
```

✅ VERIFIED verbatim, `:270-272`.

> **Correction to material in circulation.** Community documentation (`fm-provider.md`, trap 1)
> reports that *"Apple's own adapter"* implements the wrong overload and that `session.prewarm()`
> therefore does nothing for Core AI models. **At commit `5ed9981` that is not true** — the signature
> is `prewarm(model:transcript:)`, exactly matching the protocol requirement, and the body kicks off
> a real resource load. The community observation was made against an earlier snapshot. The
> *underlying* trap is real and still worth knowing when you write your own conformance:
> `LanguageModelExecutor.prewarm` has a default no-op extension, so implementing
> `prewarm(transcript:)` by mistake **compiles and is never called**. Match the signature exactly.

Note also what `prewarm` ignores: the `transcript`. It warms the *engine*, not the *prompt*. There is
no speculative prefill here.

### 8.5 The full session, with everything this guide has said applied

```swift prelude:external-module
import CoreAILanguageModels
import CoreAIShared
import FoundationModels
import Foundation

@Generable
struct VocabCard {
    @Guide(description: "The vocabulary word in the target language")
    var word: String
    @Guide(description: "The English translation")
    var translation: String
    @Guide(description: "A natural example sentence using the word")
    var exampleSentence: String
}

func makeVocabModel(at bundleURL: URL) async throws -> CoreAILanguageModel {
    // 1. Validate the bundle before the model touches it (§2.2, §2.7).
    let bundle = try ModelBundle(at: bundleURL)
    try bundle.verify()
    let lang = try LanguageBundle(bundle: bundle)
    precondition(lang.hasEmbeddedTokenizer, "\(lang.name) would fetch its tokenizer from the network")

    // 2. Sequential engine, eagerly loaded:
    //    - sequential  → supportsLogits → @Generable works           (§7.8)
    //    - .eager      → capabilities are trustworthy immediately    (§7.8 callout)
    return try await CoreAILanguageModel(
        resourcesAt: bundleURL,
        mode: .eager,
        variant: "coreai-sequential",
        kvCacheStrategy: .auto)
}

func generateCard(for word: String, using model: CoreAILanguageModel) async throws -> VocabCard {
    guard model.capabilities.contains(.guidedGeneration) else {
        throw AppError.structuredOutputUnavailable      // now a real check, not an optimistic one
    }
    let session = LanguageModelSession(model: model)
    let response = try await session.respond(
        to: "Generate a vocab card for: \(word)",
        generating: VocabCard.self)
    return response.content
}
```

Four decisions in twenty lines, each of which has a section number attached. That is the point of
this guide.

**And when you are done, release it.** `model.unload()` tears the engine down — borrow-safe, so it
is fine to call while a stream is in flight (§4.3). On iOS with a multi-GB bundle, unloading on
`scenePhase == .background` is the difference between surviving a jetsam sweep and not.

---

## 9. Bring your own sampling

Session 324 promises *"your own custom models **and token sampling strategies**"* (✅ VERBATIM
324:186). Here is exactly how much of that is true, and where the seams are.

### 9.1 `SamplingConfiguration` — the declarative half

✅ VERIFIED, `Samplers/SamplingConfiguration.swift:43-…`:

```swift prelude:guide-context
public struct SamplingConfiguration: Sendable, Equatable, Hashable {
    public let temperature: Double
    public let topK: Int?
    public let topP: Double?
    public let minP: Double?
    public let combined: Bool                 // default true

    public init(temperature: Double, topK: Int? = nil, topP: Double? = nil,
                minP: Double? = nil, combined: Bool = true)

    public static let greedy = SamplingConfiguration(temperature: 0)
    public static func temperature(_ t: Double) -> SamplingConfiguration
    public var isGreedy: Bool                 // temperature == 0
    public var isComposite: Bool              // temperature > 0 && (topK|topP|minP != nil)
    public func validateAndWarn()
    public func normalized() -> SamplingConfiguration
    public func fallbackSampler(from logits: inout [LogitsScalarType]) -> Int32
}
```

The documented application order, verbatim from the type's doc comment (`:16-22`):

```
1. Temperature scaling (logits / temperature)
2. MinP filtering (relative probability threshold)
3. TopP filtering (cumulative probability cutoff)
4. TopK filtering (hard limit on vocabulary)
5. Softmax and multinomial sampling
```

⚠️ Note that order: **minP before topP before topK**, which is *not* the order most inference stacks
use (llama.cpp and mlx-lm both apply topK first). If you are porting sampling parameters from another
runtime to get matching output, the parameters transfer but the results will not.

> ⚠️ **`init` uses `precondition`, not `throws`.** ✅ VERIFIED (`:111-114`): `temperature >= 0`,
> `topK > 0` if set, `topP ∈ (0, 1]` if set, `minP ∈ (0, 1]` if set. A `topP` of `0` read from a
> server-side config, a user slider that reaches 0, or a JSON decode of `1.5` **crashes your app** in
> any build with checks enabled. Validate before you construct:
> ```swift
> func safeSampling(temperature: Double, topP: Double?) -> SamplingConfiguration {
>     let t = max(0, temperature)
>     let p = topP.flatMap { $0 > 0 && $0 <= 1 ? $0 : nil }
>     return SamplingConfiguration(temperature: t, topP: p)
> }
> ```

`validateAndWarn()` catches the merely-suspicious rather than the fatal: `topK == 1` with
`temperature > 0`, `topP == 1.0`, `minP == 1.0`, minP and topP together, and any of the three with
`temperature == 0`. Call it once at startup when you accept sampling parameters from a config file;
it will not throw, it just logs.

`combined: false` is the instrumentation switch — *"Disabling the combined operation will allow more
fine-grained instrumentation of discrete steps"* at the cost of an extra synchronization point.
`llm-runner --synchronous-sampling` sets it. Use it when you are profiling, not in production.

### 9.2 Two sampler implementations, one per engine

**`CompositeSampler` — CPU** (✅ `Samplers/CompositeSampler.swift`):

```swift prelude:guide-context
public struct CompositeSampler {
    public static func sample(from logits: inout [Float16], config: SamplingConfiguration) -> Int32
    public static func sample(from logits: inout [Float],   config: SamplingConfiguration) -> Int32
    // plus `using rng: inout some RandomNumberGenerator` overloads for deterministic tests
    public static func allMasked(_ logits: [Float16]) -> Bool
    public static func allMasked(_ logits: [Float]) -> Bool
}
```

Three paths inside: greedy (vImage `Planar16F→PlanarF` then `vDSP_maxvi`); a fast path with no
topK/topP/minP (vectorised softmax via `vDSP_vsdiv`, `vDSP_maxv`, `vvexpf`, `vDSP_sve`, then
inverse-CDF multinomial); and a slow path that builds an active-index set with a min-heap top-K in
O(V log K), applies minP **in logit space** as `logit >= maxLogit + logf(minP)`, computes topP over
the K-sized window only, then softmaxes and samples over the compacted subset.

`allMasked(_:)` exists specifically for §7: it detects an all-`-inf`/NaN logits vector, i.e. a grammar
that has blocked everything. And the doc note confirms the masking design: guided generation works
through *either* path because masked positions are `-.infinity` (or
`-Float16.greatestFiniteMagnitude`) and `exp()` them to 0.

**`MPSGraphSampler` — GPU** (✅ `Samplers/MPSGraphSamplers.swift`):

```swift illustrative
protocol MPSGraphSampler: AnyObject, Sendable {
    var vocabSize: Int { get }
    func encode(to queue: MTLCommandQueue, logitsBuffer: MTLBuffer, logitsOffset: Int,
                outputBuffer: MTLBuffer, outputOffset: Int, completion: @escaping (Int32) -> Void)
    func encodeWithSlice(to queue: MTLCommandQueue, logitsBuffer: MTLBuffer, queryLength: Int,
                         outputBuffer: MTLBuffer, outputOffset: Int, completion: @escaping (Int32) -> Void)
}
enum MPSGraphSamplerFactory {
    static func makeSampler(device:vocabSize:config:) throws -> any MPSGraphSampler
}
```

`temperature == 0` selects `MPSGraphArgmaxSampler`; anything else selects
`MPSGraphCompositeSampler`. Effective K when you do not set `topK`: `min(1000, vocabSize)` if topP or
minP is set, else **40**.

Note the protocol: it is `internal`, and it takes `MTLBuffer`s and a completion closure — the token
never becomes a Swift value until the callback. **That is the design that makes logits unavailable**,
and it is not an oversight; it is what the pipeline is for.

### 9.3 What "bring your own sampling strategy" actually means

Three levels, in increasing order of what you have to write.

**Level 1 — parameters, on the non-FM path.** topK/topP/minP are unreachable through
`GenerationOptions` (§8.3), but they are reachable through `TextGenerator`:

```swift prelude:guide-context
let generator = try await TextGeneratorBuilder()
    .withInferenceEngine(engine)
    .withSampling(configuration: SamplingConfiguration(
        temperature: 0.8, topK: 50, topP: 0.9))
    .withDecoding(type: .vanilla, parameters: DecodingParameters())
    .withTokenizer(tokenizer)
    .build()

let text = try await generator.generate(
    input: .prompt("Write a haiku about compilers"),
    maxTokens: 60,
    stopSequences: nil)                 // nil ⇒ StopSequences(for: tokenizer)
```

✅ VERIFIED, `TextGeneration/TextGenerator.swift:172-241` (builder) and `:37-60` (generate). The
`Input` enum is `case rawText(String)` / `case prompt(String)` / `case tokens([Int])` — `.prompt`
applies the chat template, `.rawText` does not (✅ `:271-…`, `PromptUtils.maybeApplyTokenizerChatTemplate`).

`TextGenerator` also gives you the two things Foundation Models does not expose at all:

```swift illustrative
let (text, logits) = try await generator.generateWithLogits(input: .prompt("…"), maxTokens: 50)
let result = try await generator.evaluateContinuation(context: ctx, continuation: cont)
```

`evaluateContinuation` runs `generate(with: contextTokens, …,
InferenceOptions(maxTokens: contTokens.count, includeLogits: true, forcedContinuation: contTokens))`
between two `reset()`s — the MMLU-style `P(continuation | context)` primitive (§5.1). Both require
`supportsLogits`, i.e. not the pipelined engine.

**Level 2 — a custom `DecodingStrategy`.** This is the real extension point, and it is public:

```swift prelude:guide-context
public protocol DecodingStrategy: Sendable {
    associatedtype ResultSequence: AsyncSequence<GenerationResult, Error>
    func decode(
        from input: Input,
        tokenizer: any Tokenizer,
        inferenceEngine: any InferenceEngine,
        samplingConfiguration: SamplingConfiguration,
        options: InferenceOptions,
        stopSequences: StopSequences
    ) async throws -> ResultSequence
}
```

✅ VERIFIED, `DecodingStrategies/DecodingStrategy.swift:158-182`. `ConstrainedDecodingStrategy`
(§7.6) is an implementation of exactly this protocol, and it is the model to copy: request
`includeLogits: true`, run one step at a time, do whatever you like to the logits array, sample,
feed the token back. Speculative decoding, repetition penalties, logit bias, banned-phrase filtering,
watermarking — all of it lives here.

⚠️ But note the factory (`:187-207`):

```swift illustrative
public static func create(type: DecodingType, parameters: DecodingParameters = DecodingParameters())
    -> any DecodingStrategy
{
    switch type {
    case .vanilla:
        return VanillaDecodingStrategy()
    }
}

public enum DecodingType {
    case vanilla
}
```

**`DecodingType` has one case, and `TextGeneratorBuilder.withDecoding(type:)` takes a `DecodingType`,
not a strategy.** So the builder cannot construct your custom strategy — even though `TextGenerator`'s
*designated initializer* takes `decodingStrategy: any DecodingStrategy` directly (`:19-28`). Bypass
the builder:

```swift prelude:guide-context
let generator = TextGenerator(
    inferenceEngine: engine,
    samplingConfiguration: SamplingConfiguration(temperature: 0.8, topK: 40),
    decodingStrategy: MyRepetitionPenaltyStrategy(penalty: 1.1),
    tokenizer: tokenizer)
```

That compiles today, and it is how you actually plug a custom decoder in. `DecodingType` is
vestigial.

**Level 3 — your own `LanguageModelExecutor`.** If you want a custom strategy behind
`LanguageModelSession`, `CoreAIExecutor` will not do it for you: it hard-codes the vanilla/constrained
branch on `request.schema`. Write your own conformance (Part 4 reference 03), reusing
`CoreAIRunner(bundle:).makeInferenceEngine()` and `LanguageBundle.loadTokenizer()` as the public
building blocks — both are `public`, both work standalone, and that is exactly what the community
`ZooFMProvider` does in ~200 lines to add tool calling that Apple's adapter did not have at the time.

### 9.4 What you cannot override

Be clear-eyed about the boundaries:

| | Overridable? |
|---|---|
| Sampling parameters (temp/topK/topP/minP) | ✅ on the `TextGenerator`/engine path; ❌ (temp only) through Foundation Models |
| The per-step decode loop | ✅ via `DecodingStrategy` |
| Logit post-processing (bias, penalties, masks) | ✅ via `DecodingStrategy`, **if `supportsLogits`** |
| The CPU sampler's internals | ❌ `CompositeSampler` is a `public struct` with only `static` methods; no injection point |
| The GPU sampler | ❌ `MPSGraphSampler` is `internal`, and the token never reaches Swift anyway |
| The engine | ✅ `InferenceEngine` is public — you can conform your own |
| Engine selection | ⚠️ only by variant string; `Variant` is `private` |

The honest summary of session 324's promise: **"bring your own token sampling strategies" is true at
the decoding-strategy level and on the sequential engine.** On the pipelined GPU engine, sampling is
a compiled MPSGraph and the only knobs are the ones `SamplingConfiguration` declares.

---

## 10. Quick reference

### 10.1 Decision table

| If you need… | Do this |
|---|---|
| Fastest decode on macOS | default — `.dynamic` auto-selects pipelined |
| `@Generable` / JSON schema on macOS | `variant: "coreai-sequential"` (§7.8) |
| `@Generable` on iOS | default — `.chunkedStatic` auto-selects static-shape, which has logits |
| MMLU-style evaluation (`forcedContinuation`) | sequential or static-shape; `TextGenerator.evaluateContinuation` |
| topK / topP / minP | the `TextGenerator` path, not Foundation Models (§9.3) |
| Multi-turn TTFT that does not grow | feed the **full running sequence** every turn (§6.1) |
| Bounded memory on a long conversation | trim your transcript; **not** `.chunked` (§5.7) |
| Bounded prefill memory | `COREAI_CHUNK_THRESHOLD` before engine creation (§5.7) |
| Two independent conversations, one bundle | vary the `Configuration` or serialize (§4.3) |
| Trustworthy `capabilities` | `mode: .eager` or `try await model.load()` first (§7.8) |
| A model on the Neural Engine | export multi-function / chunked-static; the *structure* picks the unit (§4.2) |

### 10.2 The eight things that fail silently

1. **`compression` in `metadata.json` records the request, not the result.** A failed quantization
   logs a warning and ships fp16. §2.11
2. **A missing `tokenizer/` falls back to a HuggingFace Hub fetch** — invisible on your Mac, broken
   on a user's device. §2.7
3. **`capabilities` claims `.guidedGeneration` before the engine loads**, then generation throws.
   §7.8
4. **`stopTokenIds` is accepted, logged, and discarded** by `ConstrainedGenerationSession`. §7.4
5. **`vocabType` defaults differ between initializers** (`.raw` vs `.byteLevel`) — wrong choice
   over-constrains the grammar and produces nothing, with no error. §7.5
6. **`.chunked` KV strategy is accepted and silently becomes fixed-size.** §5.7
7. **Multi-token stop sequences are dropped** on the constrained path, with a `CLILogger` warning you
   will never see in an app. §7.6
8. **The sequential engine binds I/O positionally**, so a graph declaring inputs in the wrong order
   loads, runs, and produces garbage. §5.3

Plus one that is fixed but shows the class: **pipelined sampling at temperature > 0 produced garbled
text** before commit `aff0bb2` (2026-07-23) — plausible English, no error. §5.4

### 10.3 Copy-paste: validate a bundle before you ship it

```swift prelude:external-module
import CoreAILanguageModels
import CoreAIShared
import Foundation

enum BundleAudit {
    struct Report {
        let name: String
        let kind: BundleKind
        let assets: [String: String]
        let vocabSize: Int
        let maxContextLength: Int
        let hasEmbeddedTokenizer: Bool
        let mainAssetBytes: Int?
        let isCompiled: Bool
    }

    static func audit(at url: URL) throws -> Report {
        // .aimodel / .aimodelc are directories — this throws early and clearly (§2.3).
        let bundle = try ModelBundle(at: url)

        // Every declared asset exists. CoreAILanguageModel.init does NOT do this (§2.2).
        try bundle.verify()

        let lang = try LanguageBundle(bundle: bundle)
        let mainURL = try bundle.requireModelURL(for: ModelBundle.ComponentKey.main)

        return Report(
            name: lang.name,
            kind: bundle.kind,
            assets: bundle.assets,
            vocabSize: lang.vocabSize,
            maxContextLength: lang.maxContextLength,
            hasEmbeddedTokenizer: lang.hasEmbeddedTokenizer,
            mainAssetBytes: mainURL.recursiveFileSizeInBytes(),
            isCompiled: mainURL.pathExtension.lowercased() == "aimodelc")
    }
}

// In a test target, so it fails in CI rather than in the field:
let report = try BundleAudit.audit(at: bundleURL)
#expect(report.hasEmbeddedTokenizer)                        // §2.7
#expect(report.kind == .llm)
#expect(report.vocabSize > 0 && report.maxContextLength > 0)
#expect((report.mainAssetBytes ?? 0) < expectedMaxBytes)    // §2.11 — the only compression signal
```

### 10.4 Symbol index

| Symbol | Module | Section |
|---|---|---|
| `ModelBundle`, `BundleKind`, `FunctionMap` | `CoreAIShared` | §2.2, §2.9, §2.6 |
| `LanguageBundle`, `LanguageConfig`, `VisionConfig` | `CoreAILanguageModels` | §2.6, §2.7 |
| `ModelStructure`, `PreparedModel`, `GraphNames` | `CoreAIShared` | §4.2 |
| `CoreAIRunner` | `CoreAILanguageModels` | §4.1 |
| `InferenceEngine`, `InferenceOptions`, `InferenceOutput`, `StopReason` | `CoreAILanguageModels` | §5.1 |
| `EngineFactory`, `EngineOptions`, `KVCacheStrategy` | `CoreAILanguageModels` | §5.2, §5.7 |
| `CoreAISequentialEngine` / `CoreAIPipelinedEngine` / `StaticShapeEngine` | `CoreAILanguageModels` | §5.3–5.5 |
| `MultimodalInferenceEngine`, `EmbeddedInput` | `CoreAILanguageModels` | §5.6 |
| `TokenHistory` | `CoreAILanguageModels` | §6.1 |
| `CompiledGrammar`, `GrammarCompiler`, `GrammarMatcher`, `XGrammarError` | `CoreAILanguageModels` | §7.2 |
| `ConstrainedGenerationSession`, `TokenizerInfo`, `VocabularyType` | `CoreAILanguageModels` | §7.3–7.5 |
| `DecodingStrategy`, `ConstrainedDecodingStrategy`, `StopSequences`, `GenerationResult` | `CoreAILanguageModels` | §7.6, §9.3 |
| `CoreAILanguageModel`, `CoreAIExecutor` | `CoreAILanguageModels` | §8 |
| `SamplingConfiguration`, `CompositeSampler` | `CoreAILanguageModels` | §9.1, §9.2 |
| `TextGenerator`, `TextGeneratorBuilder`, `Input`, `PromptUtils` | `CoreAILanguageModels` | §9.3 |

### 10.5 Cross-links

- **Part 7 ref 01** — `AIModel` / `InferenceFunction` / `NDArray`, the layer under all of this.
- **Part 7 ref 02** — specialization, the model cache, `xcrun coreai-build`. §2.10 is its bundle-side
  consequence.
- **Part 7 ref 03** — states as KV cache and the `encode` API the pipelined engine is built on.
- **Part 4 ref 02** — choosing a backend as an app developer; the guided-generation constraint (§7.8)
  is a selection criterion there.
- **Part 4 ref 03** — authoring a `LanguageModel` conformance. `CoreAILanguageModel` is the third
  worked example; §9.3 level 3 is the hand-off point.
- **Part 4 ref 04** — executor lifecycle and KV reuse from the *protocol* side; §6 is the same problem
  from the *engine* side.
- **Part 8 / 9 / 10** — where the `.aimodel` in your bundle came from, what compression did to it, and
  how to author for the ANE.
- **Part 1** — the backend decision table, which carries "guided generation available?" as a column.

---

## 11. Sources and evidence ledger

### Primary — shipped source read this session

**`apple/coreai-models` @ `5ed9981` (2026-07-23), BSD-3-Clause.** Every `path:LINE` citation in this
guide is against this checkout. Files read in full or in the cited ranges:

- `Package.swift`, `Package.resolved`, `.spi.yml`, `models/README.md`
- `swift/Sources/CoreAIShared/Bundle/{ModelBundle,BundleKind,FunctionMap}.swift`
- `swift/Sources/CoreAIShared/Runtime/{ModelStructure,FileSize,ResourceManaging,NDArray+Helpers}.swift`
- `swift/Sources/CoreAILanguageModels/Bundle/{LanguageBundle,LanguageConfig}.swift`
- `swift/Sources/CoreAILanguageModels/InferenceEngines/{InferenceEngine,EngineFactory,TokenHistory}.swift`;
  `CoreAISequentialEngine.swift`, `CoreAIPipelinedEngine.swift`, `CoreAIStaticShapeEngine.swift`,
  `CoreAISequentialVLMEngine.swift` (headers + cited ranges)
- `swift/Sources/CoreAILanguageModels/GuidedGeneration/{ConstrainedGenerationSession,XGrammarWrapper}.swift`
  (full), `TokenizerInfo.swift`
- `swift/Sources/CoreAILanguageModels/DecodingStrategies/{DecodingStrategy,ConstrainedDecodingStrategy}.swift`
- `swift/Sources/CoreAILanguageModels/LanguageModel/{CoreAILanguageModel,CoreAIRunner,ModelResources}.swift`
- `swift/Sources/CoreAILanguageModels/{Samplers/SamplingConfiguration,Samplers/CompositeSampler,TextGeneration/TextGenerator}.swift`
- `swift/Sources/CoreAISpeech/SpeechBundle.swift`
- `swift/Sources/CoreAIDiffusionPipeline/Pipelines/{PipelineDescriptor,PipelineDescriptor+CoreAI,Flux2Pipeline+Resources}.swift`
- `python/src/coreai_models/export/{bundle,compiler}.py`;
  `python/src/coreai_models/{vlm/export,diffusion/pipeline,diffusion/components,segmentation/pipeline}.py`
- `swift/Sources/lib/CXGrammar/` (directory listing + header inventory)
- `skills/skills/working-with-coreai/SKILL.md`, `skills/skills/model-authoring/SKILL.md`

**`ml-explore/mlx-swift-lm`** — `Package.swift:110-152` and `:203-228` (target table, the
namespace-rename comment naming *"CoreAI's prebuilt copy"*, the `v0.1.30` xgrammar pin), plus the
`MLXGuidedGeneration` target description.

**`john-rocky/coreai-models`** (community fork, 4 commits) —
`InferenceEngines/InferenceEngine.swift:100-195`, `CoreAISequentialEngine.swift:425-450`,
`CoreAIPipelinedEngine.swift:1401-1415`. Commits `0fdf710`, `627fec7`, `9e5b605`.

### Secondary — Apple prose

- **WWDC26 session 324, "Meet Core AI."** Quoted at 324:182-186 (the Core AI Models repo and the
  Foundation Models bridge). 🟡 spoken narration; every API name it implies was checked against
  source.
- **WWDC26 session 326, "Core AI app features."** Quoted at 326:94-99 (products), 326:103-118 (the
  Foundation Models bridge), 326:140-170 (deployment: >1 GB, Background Assets, first-run
  specialization, `coreai-build`). 🟡 spoken narration.
- **WWDC26 session 325, "Dive into Core AI model authoring and optimization"** — referenced by
  `models/sam3/README.md` for the three-function split. The 76 % figure is Apple-published with no
  hardware attached.
- Apple's own agent skills in `apple/coreai-models/skills/` — treated as strong evidence (Apple's
  empirical rules, shipped in an Apple repo), cited where used.

### Tertiary — community, always labelled as such

**`john-rocky/coreai-model-zoo`** (`knowledge/`, 77 files). Single-author community material with
self-declared uncontrolled benchmarks. Used for: the M4 Max and iPhone 17 Pro benchmark tables (§5.9),
the `COREAI_CHUNK_THRESHOLD` sweep (§5.7), the prefix-reuse speedups (§6.6), the two-model footprint
numbers (§7.8), the KV-corruption and prewarm observations (§4.3, §8.4), and the guided-generation /
logits differential (§7.8). **Every one of those is attributed inline as community-measured with
hardware and OS where the source states it, and flagged where it does not.**

### Conflicts resolved in this guide

| Claim in circulation | What the source says |
|---|---|
| *"Apple's `CoreAILanguageModel` implements the wrong `prewarm` overload, so `session.prewarm()` is a no-op"* (community `fm-provider.md`) | ❌ Superseded at `5ed9981`: the signature is `prewarm(model:transcript:)` and the body loads resources (`:270-272`). The underlying protocol trap is real; Apple's adapter no longer exhibits it. §8.4 |
| *"`function_map` has no consumer"* | ❌ Partly wrong: `CoreAIRunner.makeConfig` reads `functionMap?.name(for: "main")` (`:74`). The **multi-name** case still has no verified consumer. §2.6 |
| `models/sam3/README.md`: `import ImageSegmenter` | ❌ Not a module. The module is `CoreAIImageSegmenter`, the product is `CoreAISegmentation`. §3.1 |
| `CoreAILanguageModel.init` doc: variant `"ane"` | ❌ Not a valid variant; `Variant(rawValue: "ane")` is `nil`. Use `"static-shape"`. §5.8 |
| *"Core AI can't do guided generation"* | ❌ Too broad. Three of four engines can; the **GPU-pipelined** one cannot, and it is the macOS default. §7.8 |
| `--dynamic-sized-kvcache-gpu`, suggested by Swift error text | 🔴 No such flag exists in any Python export CLI in this repo. §5.7 |
| `pipeline.json` for diffusion bundles | ❌ Now a hard error in `.auto` mode. §2.8 |

### Declared gaps

| # | Unknown | What would resolve it | Safe default meanwhile |
|---|---|---|---|
| 1 | Multi-name / renaming `function_map` — is it honoured by `StaticShapeEngine`? | a chunked-static bundle with non-conventional entrypoint names, run under `llm-runner --verbose-level 2` | name functions by convention; use `function_map` only for `main` |
| 2 | Does `metadata.json` (or the asset) ever record *achieved* compression? | `AIModelAsset.summary(includingStatistics: true)` on a compiled asset, or SDK metadata dump | treat `compression` as a request; gate on artifact size in CI |
| 3 | Where the `encoder.aimodel` + `decoder.aimodel` speech export lives | an Apple statement or a future commit | treat `CoreAISpeech` as pre-release; use `SpeechAnalyzer` or the legacy single-`main` path |
| 4 | What `COREAI_QUERY_BUCKET_SIZE` does at runtime | Core AI framework headers, or an Instruments trace across values | leave it alone (default 64) |
| 5 | Does upstream xgrammar's C++ `TokenizerInfo` support stop-token ids? | read `mlc-ai/xgrammar` @ `4d145cc1…` | do not rely on `stopTokenIds`; check `isTerminated` after every accept |
| 6 | Is `SystemLanguageModel`'s structured output the same xgrammar mechanism? | framework symbol inspection | reason about your own models with §7; treat the built-in model as a black box |
| 7 | VLM sub-model loading: concurrent (`CoreAIVisionLanguageModel`) or sequential (`llm-runner`)? | an Apple statement, or a repro of the "runtime errors with concurrent model preparation" the CLI comment cites | load multi-asset bundles sequentially |
| 8 | Sequential-vs-pipelined decode throughput on identical hardware | `llm-benchmark --inference-engine-variant coreai-sequential` against a bundle you already benchmarked pipelined | measure it yourself before committing to §7.8 option 1 |
| 9 | Community `trimKVCache` on the pipelined engine | a multi-turn pipelined device harness; blocked on a `GrowingLogitsBuffer` SIGTRAP in the source's own testing | assume sequential-only |

---

*Part 7 · Reference 04. Verified against `apple/coreai-models` @ `5ed9981` (2026-07-23),
`ml-explore/mlx-swift-lm` @ `3cbf928` (2026-07-24), and WWDC26 sessions 324 / 325 / 326.
Guide compiled 2026-07-27. Everything here is beta-era: check the commit before you trust a
signature.*

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
