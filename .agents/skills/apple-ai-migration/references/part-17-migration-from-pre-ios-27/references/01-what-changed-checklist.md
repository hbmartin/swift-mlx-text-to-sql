# What changed between iOS 26 and iOS 27: the complete checklist

**Part 17 · Migration from pre-iOS 27 · Reference 01**

**Version floor: this guide assumes you shipped against iOS/iPadOS/macOS/visionOS 26.x with Xcode 26,
and are moving to 27.** Four OS floors are load-bearing and are routinely confused —
**26.0** (the Foundation Models framework itself), **26.4** (`contextSize`, `tokenCount(for:)`,
reduced guardrail false positives, a new on-device model), **27.0** (the `LanguageModel` protocol,
`PrivateCloudComputeLanguageModel`, `ContextOptions`, Dynamic Profiles, Core AI, watchOS), and a
*fifth* ladder that belongs to a different framework entirely — Metal Performance Primitives /
TensorOps, which advances at **26.0 → 26.1 → 26.3 → 26.4** and has no 26.2 step. Build with
**Xcode 27**; nothing below about the new error taxonomy takes effect until you do, and that is the
single most expensive sentence in this guide.

> ⚠️ **SILENT FAILURE — the whole point of this part.** Apple states it in the deprecation notice on
> `LanguageModelSession.GenerationError`, verbatim:
> *"Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You
> must update to Xcode 27 to catch the new error types before submitting your app."*
> Read that as: **your `catch` blocks change meaning as a side effect of changing your build machine,
> with no compiler diagnostic, no runtime warning, and no crash.** Almost every item in the
> BEHAVIOURAL section below has that same shape.

---

## What this covers

The exhaustive 26 → 27 diff for Apple's on-device AI stack, organised by framework, with **every
item labelled**:

| Label | Meaning | What it costs you |
|---|---|---|
| **ADDITIVE** | New surface. Nothing you wrote stops working. | Time to learn, if you want it. |
| **BEHAVIOURAL** | Same source, different runtime behaviour. | The dangerous one. Your diff is empty. |
| **RENAMED** | Old spelling deprecated or superseded; usually both spellings coexist for a cycle. | A rebuild, and a decision about which to catch. |
| **WITHDRAWN** | Gone, with no drop-in replacement. | A feature redesign. |

Specifically:

- **The version-floor table**, first, because it resolves more phantom bugs than anything else here.
  Including the separate **TensorOps ladder** and the reason a header can say "26.2" while Apple's
  narration says "26.1 / 26.3 / 26.4" and *both be true*.
- **Everything additive**, from image input on the on-device model through to the `fm` CLI — with
  the two system tools that live in **Vision, not FoundationModels**, which is where most people
  look first and fail.
- **Everything behavioural** — the rebuilt on-device model, the guardrail changes, the refusal
  traffic that moved between two different error mechanisms, and Apple's own samples quietly
  abandoning proactive availability gating.
- **A known defect, not a design**: `SystemLanguageModel.default.availability` returning
  `.appleIntelligenceNotEnabled` unless the user has Siri turned on. An Apple Frameworks Engineer
  said on the record that this should not happen. Do **not** build permanent UX around it.
- **The renames**, including the one that is the migration in miniature: Apple's own Technical Note
  and Apple's own 2026 sample code name *different* errors for the same failure, and both are current.
- **What was withdrawn** — custom LoRA adapters — summarised here and owned by guide 17.2.
- **The Python SDK generation lag**, stated plainly: `apple/python-apple-fm-sdk` is a **26-generation
  artifact** and does not expose the 27 feature set.
- **A toolchain-breakage table** for the build failures that are not your code's fault.
- **A migration checklist** you can work down in order.

## What this does *not* cover

- **The error mapping in detail** — old case to new case, which `catch` fires when, and the
  regression-test recipe. That is [guide 17.3](03-error-taxonomy-migration.md); this guide gives you
  the summary and the version story.
- **The adapter sunset in detail** — what to do about a shipped `.fmadapter`. That is
  [guide 17.2](02-adapter-sunset.md).
- **Dual-SDK compilation technique** — `#if canImport(FoundationModels, _version: 2)` versus
  `@available` versus SDK checks. That is [guide 17.4](04-dual-sdk-builds.md); this guide names the
  symbols that are hard 27-only so you know what needs it.
- **Core ML → Core AI.** [Guide 17.5](05-coreml-to-coreai.md).
- **Build-artifact compatibility** — `.aimodel` assets, wheel pinning, `mlx-swift-lm` 2.x → 3.x.
  [Guide 17.6](06-toolchain-and-asset-compatibility.md).
- **How to *use* any of the new APIs.** Parts 2, 3, 4 and 6 do that. This is a diff, not a tutorial.

## What you need

- **Xcode 27.** Several items below are invisible until you rebuild with it — that is the point.
- **A physical device on 27.0 or later.** The Simulator runs the on-device model by punching out to
  the host macOS (§6.9), so a Simulator result on a macOS 26 host tells you about macOS 26.
- **Your 26.x prompts, saved.** You are going to need to diff model output, and there is no model
  version pinning API to fall back on.
- Optional but strongly recommended: the **Evaluations** framework (Xcode 27) wired up *before* you
  change anything, so you have a before-picture. See [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

---

## Contents

1. [The four version floors — the table](#1-the-four-version-floors--the-table)
2. [The TensorOps ladder is a different ladder](#2-the-tensorops-ladder-is-a-different-ladder)
3. [The three on-device model versions](#3-the-three-on-device-model-versions)
4. [ADDITIVE — Foundation Models](#4-additive--foundation-models)
5. [ADDITIVE — beyond Foundation Models](#5-additive--beyond-foundation-models)
6. [BEHAVIOURAL — the category where your diff is empty](#6-behavioural--the-category-where-your-diff-is-empty)
7. [RENAMED and SUPERSEDED](#7-renamed-and-superseded)
8. [WITHDRAWN](#8-withdrawn)
9. [The Python SDK generation lag](#9-the-python-sdk-generation-lag)
10. [Toolchain breakages](#10-toolchain-breakages)
11. [Every silent failure in this migration, collected](#11-every-silent-failure-in-this-migration-collected)
12. [The migration checklist](#12-the-migration-checklist)
13. [Quick reference: the one-page diff](#13-quick-reference-the-one-page-diff)
14. [Sources and evidence ledger](#14-sources-and-evidence-ledger)

---

## 1. The four version floors — the table

Start here. In the Developer Forums, version confusion is the single largest generator of bug
reports that turn out not to be bugs. Four floors matter, they are not evenly spaced, and two of
them (26.4 and 27.0) landed within a few months of each other.

> ✅ **VERIFIED** — the availability strings below are quoted from Apple's own documentation
> pages, which render an explicit availability line per symbol. Source:
> `/documentation/foundationmodels/*` symbol pages, harvested 2026-07-27.

| Floor | What arrived | Platforms as declared | Notes |
|---|---|---|---|
| **26.0** | The Foundation Models framework itself: `SystemLanguageModel`, `LanguageModelSession`, `@Generable`, `@Guide`, `Tool`, `Transcript`, `Prompt`, `Instructions`, `GenerationOptions`, `GenerationSchema`, `DynamicGenerationSchema`, `GeneratedContent`, `Response`, `ResponseStream`, `LanguageModelFeedback`, `SystemLanguageModel.supportsLocale(_:)` | `iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+, macOS 26.0+, visionOS 26.0+` — **no watchOS** | The 2025 release. `supportsLocale(_:)` is part of the OS 26.0 model declaration.[^supports-locale-floor] |
| **26.4** | `SystemLanguageModel.contextSize`, `SystemLanguageModel.tokenCount(for:)`, a **new on-device model**, and **reduced guardrail false positives** | `iOS 26.4+, iPadOS 26.4+, Mac Catalyst 26.4+, macOS 26.4+, visionOS 26.4+` | A mid-cycle model swap, not just an API addition. See §3. |
| **27.0** | The `LanguageModel` / `LanguageModelExecutor` protocol pair, `PrivateCloudComputeLanguageModel`, `ContextOptions`, Dynamic Profiles, `LanguageModelError`, `Attachment` / image input, `GenerationOptions.ToolCallingMode`, `TranscriptErrorHandlingPolicy`, `LanguageModelSession.Usage`, `Transcript.history`, `Transcript.structuredTranscript`, Core AI, **watchOS** | `iOS 27.0+ Beta, … watchOS 27.0+ Beta` | The 2026 release. Everything marked *Beta* as of this writing. |

And the floor that isn't an OS floor at all:

| Floor | What it gates |
|---|---|
| **Xcode 27** | The **Evaluations** framework; the new error types actually being thrown into your `catch` clauses (§6.1); `canImport(FoundationModels, _version: 2)` evaluating true; `MLXFoundationModels` compiling to anything other than an empty library. |
| **macOS 27** | The `fm` command-line tool, pre-installed. |

### 1.1 The floor that is easy to miss: `contextSize` is back-deployed

`contextSize` looks like a 26.4 symbol, and functionally it is. But it carries an explicit
back-deployment attribute, which changes what you can and cannot write:

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/contextsize`, verbatim
> declaration; now also ✅ **SDK-verified** in both captured interfaces
> (`FoundationModels-26.5-macos.swiftinterface:631-634`, `FoundationModels-27.0:438-441`):
> ```swift
> @backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
> final var contextSize: Int { get }
> ```

Two consequences:

1. `contextSize` is available to code built with the **26.4 SDK**. It does *not* require the 27 SDK,
   and you should not hide it behind a `#if canImport(FoundationModels, _version: 2)` gate. A
   shipping third-party app makes exactly this point in a source comment:
   *"`contextSize` is available in the Xcode 26.4+ SDK, so it must not be hidden behind the Xcode 27
   gate."* (community source; attributed as such).
2. Because it is back-deployed, the implementation ships in your binary, so it works on OS versions
   below 26.4 — and the interfaces now show what it returns there: the emitted fallback body
   **hardcodes `4096`** (visible verbatim in both dumps — `26.5:634-643` ends in a bare `4096`;
   `27.0:445-451` reads `if #available(27.0) { return _contextSize } … return 4096`). So on a
   pre-26.4 runtime you get the constant, not the device's real budget. The `<= 0`-is-unknown
   defensive check below is therefore belt-and-braces rather than load-bearing; keep it anyway —
   it is free.

```swift compile:27
import FoundationModels

/// Returns the model's context budget in tokens, or a conservative fallback.
///
/// ✅ `contextSize` verified at /documentation/foundationmodels/systemlanguagemodel/contextsize
/// (iOS/macOS/visionOS 26.4+, @backDeployed).
func contextBudget() -> Int {
    let reported = SystemLanguageModel.default.contextSize
    guard reported > 0 else {
        // Apple's TN3193 states 4096 for the on-device model. Use it only as a floor;
        // never as the number you plan against.
        return 4096
    }
    return reported
}
```

> ✅ **VERIFIED** — Apple Technical Note **TN3193**, *"Managing the on-device foundation model's
> context window"*, states **4096 tokens per `LanguageModelSession`** plainly, and confirms that
> `tokenCount(for:)` covers *instructions, prompts, tools, schemas and transcript entries*.
> (Note the doc slug: `…tn3193-managing-the-on-device-foundation-model-s-context-window` — `model-s`,
> not `models`; the other spelling 404s.)
>
> ✅ **VERIFIED 2026-08-02 — Apple's written summary gives 4096 for iOS 27, and the budget is
> shared.** The published Q&A summary for WWDC26 **Group Lab 8121**, *"Coding Intelligence,
> Machine Learning & AI Group Lab"*, records a question about the on-device Foundation Models
> context window in iOS 27 and whether input plus output share one budget. It gives **4096 tokens
> as the on-device shared budget**, illustrates that a 4,000-token input leaves roughly 96 tokens
> for the response, and gives **32K as PCC's shared budget** (ch. `0:08:11`).[^ctx-grouplab]
>
> This supersedes the earlier 🟡 box, which recorded that "Apple has not corroborated 8192 anywhere
> we can find" and left the question open. The 8192 comment is now retired historical provenance.
> Apple has corroborated **4096**, for iOS 27
> specifically, on the record. Four other lines of evidence agree: session 319's comparison table
> and Apple's PCC article (4K/32K), the repo's simulator measurement, a **2026-08-20 physical
> iPhone 15 Pro measurement** (4096 on iOS 27 beta-5 build `24A5408d`, `probes/`), and the 27.0
> `swiftinterface`, which returns a dynamic `_contextSize` on OS 27+ with a **4096 fallback** below
> it.
>
> **The community 8192 report is retired from active guidance.** It is a single comment describing
> device probing with no device/build/date, its upstream is unavailable, and repeated project-run
> 27-hardware checks returned 4096. One iPhone family cannot
> prove every device reports the same value, which is exactly why the standing advice below does
> not change.
>
> ⚠️ **Read `contextSize` at runtime rather than hardcoding either number.** Apple's answer is a
> statement about the platform, not a per-device guarantee, and the 27.0 interface plainly returns
> a *dynamic* value. The advice is version-proof; the constants are not.
>
> **Budget accounting, from the same lab:** ch. `0:39:42` adds that **every tool definition and
> instruction consumes the same shared budget** — *"keep prompts and tool definitions lean … only
> include the tools relevant to the task"*. That matches TN3193's list above
> (instructions, prompts, tools, schemas, transcript entries) and is the operational reason the
> 4096 figure bites sooner than people expect.

[^ctx-grouplab]: WWDC26 Group Lab **8121**, `https://developer.apple.com/videos/play/wwdc2026/8121/`.
    ⚠️ **Citation discipline for Group Labs:** Apple publishes **no caption track** for lab
    sessions — only a chaptered Q&A index with Apple's own written summary per answer. Quotations
    above are from Apple's published summary text, so cite them as *Apple's paraphrase of the
    panel*, never as an engineer's spoken words. Analysis:
    `notes/web/2026-08-02-harvest/wwdc2026-8121-ml-ai-group-lab.md`.

### 1.2 Deployment target vs SDK vs runtime OS

Four different version numbers are in play at once, and mixing them up produces most of the
"it works on my machine" traffic in this area.

| Number | Set by | Governs |
|---|---|---|
| **Deployment target** | your project's `IPHONEOS_DEPLOYMENT_TARGET` etc. | which `@available` checks the compiler forces you to write |
| **SDK version** | which Xcode you build with | which *symbols exist at all*; whether `canImport(FoundationModels, _version: 2)` is true; **which error types your `catch` clauses bind** |
| **Runtime OS** | the device the user is holding | which model runs, which guardrails apply, whether specialization caches are valid |
| **Host macOS** (Simulator only) | your Mac | **the model that actually answers**, because the Simulator punches out to the host — §6.9 |

For reference, Apple's own 2026 sample sets its floor at the top:

> ✅ **VERIFIED** — the Origami sample's `project.pbxproj`:
> `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, `MACOSX_DEPLOYMENT_TARGET = 27.0`,
> `XROS_DEPLOYMENT_TARGET = 27.0`, `SWIFT_VERSION = 6.0`.
> That is why the sample contains **no `#available` guards at all** — it can't need any. Your app
> almost certainly can.

---

## 2. The TensorOps ladder is a different ladder

If you are anywhere near Metal kernels, this is the correction that matters most, and it is the one
most likely to already be wrong in your notes.

**Metal Performance Primitives / TensorOps does not advance at the same cadence as Foundation
Models, and its ladder skips 26.2.**

> ✅ **VERIFIED** — Apple Tech Talk **111432**, *"Accelerate your machine learning workloads with
> the M5 and A19 GPUs"*, gives an explicit per-point-release feature ladder:

| Release | TensorOps feature |
|---|---|
| **26.0** | Introduction (WWDC25 session 262) |
| **26.1** | **bfloat** tensor support |
| **26.3** | **cooperative tensors as *inputs* to `matmul2d`** — this is what enables custom in-kernel dequantisation |
| **26.4** | **4-bit and 8-bit integer tensors** |

**26.2 is never mentioned in that ladder.**

And yet:

> ✅ **VERIFIED** — the `MetalPerformancePrimitives` headers shipped in the **Xcode 26.6 SDK**
> annotate the symbol availability as **26.2**.

Both statements are true, and they are about different things. The **feature ladder** is Apple
narrating when capabilities became usable. The **header annotation** is the availability attribute
attached to particular symbols, which happens to be 26.2. Writing a blanket "TensorOps is 26.2" in a
migration doc conflates them and will send a reader looking for bfloat support in the wrong release.

> ⚠️ **Do not carry a blanket "26.2" into your own notes.** Write the ladder. If you need one
> number for a symbol you can see in a header, quote the header's annotation and say it's a header
> annotation.

Xcode 27 adds a separate low-bit and block-scaling wave that the Xcode 26 headers cannot reveal:

- **`MTLTensor` now has auxiliary scale planes.** `MTLTensorAuxiliaryPlaneDescriptor` describes a
  scales plane and its `blockFactors`, while `MTLTensorDescriptor.auxiliaryPlanes` carries the map
  used to associate that metadata with the tensor.[^metal-auxiliary-plane][^metal-auxiliary-map]
- **The datatype set now includes int2, FP4, FP8, and E8M0.** These are Metal 27 datatypes, not merely
  MLX helper structs; the framework uses the E8M0 auxiliary scale plane to dequantize low-bit values
  automatically for an operation.[^metal-low-bit-types][^wwdc330]

Keep the release boundary explicit. On 27, prefer the native low-bit tensor plus auxiliary-plane
contract. On 26.x, where those declarations are absent, cooperative-tensor/custom-kernel
dequantization remains the compatible fallback; do not reference the 27 symbols from a 26-SDK build.

Full treatment is [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md). The important migration distinction
is now **Xcode 26 fallback versus Xcode 27 native scale-plane support**, not “no 27 release.”

---

## 3. The three on-device model versions

This is the fact that makes the whole BEHAVIOURAL section make sense, and Apple states it flatly.

> ✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel`, verbatim:
> *"Apple periodically updates `SystemLanguageModel` in routine OS updates… Currently there are 3
> model versions that align with:*
> - *iOS, iPadOS, macOS, and visionOS 26.0 - 26.3*
> - *iOS, iPadOS, macOS, and visionOS 26.4*
> - *iOS, iPadOS, macOS, visionOS, **and watchOS** 27.0"*

So between the release you shipped against and the release your users are updating to, the model
underneath your prompts changed **twice** — once at 26.4 and once at 27.0. Neither change required
you to recompile, and neither announced itself.

Apple's own release notes say what to do about it, twice, in almost the same words:

> ✅ **VERIFIED** — `/documentation/updates/foundationmodels`, **June 2026** section, verbatim:
> *"Use the latest on-device `SystemLanguageModel` that follows instructions more accurately and
> produces better results, including in complex scenarios. **Because the model changes when a person
> updates to iOS 27, iPadOS 27, macOS 27, and visionOS 27, test your prompts with the new model to
> verify your app's behavior.**"*

> ✅ **VERIFIED** — same page, **February 2026** section (the 26.4 wave), verbatim:
> *"Use the latest on-device large language model that improves instruction-following and tool-calling
> abilities. **Because the model changes when a person updates to iOS 26.4, iPadOS 26.4, macOS 26.4,
> and visionOS 26.4, test your prompts with the new model…**"*

And WWDC26 session 241 characterises the 27 model as a ground-up rebuild:

> ✅ **VERIFIED** — WWDC26 session 241, *"What's new in Foundation Models"*, verbatim:
> *"a new on-device model, **rebuilt from the ground up**, and better across the board… It's more
> intelligent; **better at logic and tool calling**."*

### 3.1 There is no version pinning API

> ✅ **VERIFIED** — Apple Frameworks Engineer, Developer Forums thread **833642**: **no pinning API
> and no version-retrieval API** exists. The recommended mitigation is the **Evaluations framework**,
> to catch regressions between OS updates.

That is the whole reason [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) exists and why this guide keeps sending
you there. You cannot freeze the model. You can only measure it.

### 3.2 The version-gated prompt pattern

Apple documents a prompt-versioning idiom. It is worth adopting *before* you need it, because
retrofitting it after a regression means reconstructing what your old prompt was.

> ✅ **VERIFIED** — `/documentation/foundationmodels/updating-prompts-for-new-model-versions`,
> verbatim code:

```swift compile:27
if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
    // Use the prompt that you update for the the latest system version.
} else {
    // Use the prompt for the model in 26.0 to 26.3.
}
```

…and the localisation-table variant, which is the one worth actually shipping, because it keeps the
prompt text out of your source and lets you diff prompt versions like any other resource:

```swift illustrative
if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
    return String(localized: "support-ticket-summarizer-v1.1", table: "Prompts")
} else {
    return String(localized: "support-ticket-summarizer-v1.0", table: "Prompts")
}
```

Apple's two accompanying instructions, verbatim: *"Order the availability attribute from the newest
version to the oldest version… **The availability of the Foundation Models framework starts at 26.0,
so you don't need to check for versions prior to that.**"* and *"Because the older model is only
included as part of the beta program, **it's essential to produce a record of what output your prompt
produces with the prior model.**"*

> 🟡 **RECONSTRUCTED** — the obvious extension of that pattern to 27 is a third branch
> (`if #available(iOS 27.0, …)`), and it is what the structure implies. Apple's page as harvested
> shows only the 26.4 split, so treat the three-branch form as your own extrapolation rather than a
> documented recipe.

### 3.3 Two on-device model *tiers* also arrived

Separate from the version ladder, the model now forks by hardware.

> ✅ **VERIFIED** — Apple Designer (Apple), Developer Forums thread **832910**, accepted answer,
> verbatim:
> *"Yes. There is **AFM 3 Core** and **AFM 3 Core Advanced**. Previously, the same on-device model
> was available across all devices… Starting in the fall with Siri AI release:*
> *Devices with AFM 3 Core Advanced (most powerful): iPhone Air · iPhone 17 Pro · iPhone 17 Pro Max ·
> iPad (M4) or later with at least 12GB of unified memory · Mac (M3) or later with at least 12GB of
> unified memory · Apple Vision Pro (M5). All other devices: AFM 3 Core.*
> *Plan to have different models. Model details and guidance will evolve over the summer's beta
> period."*

> 🔴 **GAP** — **what actually differs between the two tiers is unpublished.** Parameter count,
> context size, modality support and tool-calling reliability are all unstated, and there is
> **no API that tells you which tier you are on** (consistent with there being no version-retrieval
> API at all — §3.1). What would resolve it: an Apple documentation page or a `SystemLanguageModel`
> property exposing the tier.
> **Safe default:** design for AFM 3 Core (the *lower* tier, which is every device not on that
> list), read `contextSize` at runtime, and evaluate on at least one device from each side of the
> split before you ship. Do not branch on device model strings — that list will change.

---

## 4. ADDITIVE — Foundation Models

Everything in this section is **new surface**. None of it breaks a 26.x codebase. You can adopt it
incrementally, and for most apps the right first move is to adopt *none* of it until §6 (behavioural)
is under control.

Apple's own summary of the release is worth reading first, because it is short and it is the closest
thing to an official changelog:

> ✅ **VERIFIED** — `/documentation/updates/foundationmodels`, **June 2026**, verbatim:
> > **General**
> > - Build multimodal agentic app experiences by using the `LanguageModelSession.DynamicProfile` API.
> > - Use the improved error types, like `LanguageModelError` for model-specific errors,
> >   `SystemLanguageModel.Error` for on-device Apple Foundation model errors, and
> >   `LanguageModelSession.Error` for errors related to the session but not the model.
> >
> > **Models**
> > - Use the latest on-device `SystemLanguageModel`…
> > - Adopt the `LanguageModel` protocol to use any large language model — server or on-device — with
> >   the Foundation Models framework.
> > - Use `PrivateCloudComputeLanguageModel` to access more reasoning capabilities and a larger
> >   context size.
> > - Perform image analysis tasks by including an image in your prompt and using tools the Vision
> >   framework provides, like `OCRTool` and `BarcodeReaderTool`.
> >
> > **Tool calling**
> > - Control how the model interacts with tools for your request by using
> >   `GenerationOptions.ToolCallingMode`.
> >
> > **Instruments**
> > - Use the updated [Analyzing the runtime performance of your Foundation Models app]…
> >
> > **Open source**
> > - Get the **Foundation Models framework utilities**… Use **CoreAILanguageModel** and
> >   **MLXLanguageModel** to integrate on-device models with the Foundation Models framework.

### 4.1 ADDITIVE — image input on the on-device model

The on-device model gained vision. This is the change with the widest blast radius among the
additive items, because it is what pulls CoreImage into the framework's module interface and
therefore what (probably) caused the watchOS build break in §10.

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"the on-device model is also gaining **Vision
> capabilities**… **Simply insert an image attachment into your prompt, together with text.**"*
> Accepted source types, read aloud in the same passage: `UIImage`, `NSImage`, `CGImage`, Core Image
> types, CoreVideo pixel buffers, and file URLs.
> *"The model supports **images in any size and aspect ratio, so you don't need to crop or pad**…
> larger images will consume more tokens and incur more latency."*

The call-site shape is confirmed by shipping Apple sample code, not just narration:

> ✅ **VERIFIED** — Apple's Origami sample uses `Attachment(image).label(_:)` inside a `Prompt {}`
> builder; `ImageReference` is a `@Generable`-usable field type resolved via
> `ImageReference.attachmentLabel`. Apple's documentation shows the same shape in the
> `BarcodeReaderTool` example (§4.6).

```swift compile:27
import FoundationModels
import Vision          // only needed for the tools in §4.6

// ✅ Shape verified against Apple's documentation example for BarcodeReaderTool
// and against the Origami sample's Attachment(...).label(...) usage.
func describe(_ image: CGImage) async throws -> String {
    let session = LanguageModelSession()
    let response = try await session.respond {
        "List every food item visible in this photo."
        Attachment(image).label("photo")
    }
    return response.content
}
```

> ⚠️ **SILENT FAILURE — the attachment identity.** `Attachment(image).label("…")` supplies the
> stable handle used by `ImageReference.attachmentLabel` and `resolved(in:)`. Without it, an
> identity-dependent result or tool cannot resolve the intended image. A 2026-08-20 iPhone 15 Pro
> probe narrowed the rule: a required generic tool ran for both labeled and unlabeled image prompts,
> while the transcript recorded the expected label versus `nil`. So omission does not universally
> suppress tool invocation; label every attachment that output or a tool must identify.

Two additional facts worth carrying into a migration plan:

> ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread **833642**: there is **no set resolution
> restriction** (the framework may resize), **image count per prompt is unlimited** (bounded only by
> the context window), and — importantly — **image input does not change which model services the
> request**. An on-device call with images stays on-device.

> 🔴 **GAP** — **spatial localisation is unreliable.** A developer reporting on thread **838613**
> found the model reliably *names* objects but produces bounding boxes that are "off by 1–2× the
> object width/height or cluster rectangles at top of image", across pixel, normalised and percentage
> coordinate conventions. Apple's reply (Apple Designer, "Recommended") did not dispute it and
> redirected to Vision: *"the Vision framework is the modern Swift successor to VisionKit that has a
> bunch of saliency and classification APIs that may be helpful."* The same developer *speculates*
> the framework downsamples to 896 px on the longest dimension — **that number is a developer
> inference, never Apple-confirmed.**
> **Safe default:** use the language model for *identification and description*; use Vision, or a
> detection model via `CoreAIObjectDetection`, for *coordinates*.

**Migration impact:** none unless you adopt it. But note that `Attachment` is a hard 27-only symbol —
it cannot be papered over with a runtime `#available` check if you are compiling against the 26 SDK,
because the type does not exist there. See [guide 17.4](04-dual-sdk-builds.md).

### 4.2 ADDITIVE — `PrivateCloudComputeLanguageModel`

> ✅ **VERIFIED** — `PrivateCloudComputeLanguageModel` is a `final class`, new at
> `iOS 27.0+ Beta … watchOS 27.0+ Beta`, listed in the framework index under **Private Cloud
> Compute** alongside the `com.apple.developer.private-cloud-compute` entitlement. Now also
> ✅ **SDK-verified**: `final public class PrivateCloudComputeLanguageModel : Sendable`
> (`27.0:43-45`), conforming to `LanguageModel`, with a detail the docs gloss over — its
> `contextSize` is **`get async throws`** (`27.0:129-138`), unlike `SystemLanguageModel`'s
> synchronous one, because answering it may require the network. The 32K figure is Apple's
> published number; no constant appears in the interface.

The switch is genuinely one line:

```swift illustrative
// 26.x
let session = LanguageModelSession()

// 27.0 — same downstream API, different backend.
let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
```

> ✅ **VERIFIED** — that exact initializer with the `model:` label appears verbatim in Developer
> Forums thread 834749 and again in an Apple engineer's reply on thread 832053.

The comparison Apple gives:

> ✅ **VERIFIED** — WWDC26 session 319 spoken table, matched **exactly** by Apple's
> *Adding server-side intelligence with Private Cloud Compute* article:

| | on-device `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` |
|---|---|---|
| Privacy | ✅ | ✅ |
| Works offline | ✅ | 🚫 requires a network |
| Request limits | none | daily per-user limit |
| Context size | **4K** | **32K** |
| Reasoning | not supported | supported, multiple levels |

**The migration-relevant part is not the API. It is the eligibility gate**, and for a large fraction
of readers the answer is "you cannot use this."

> ✅ **VERIFIED** — `https://developer.apple.com/private-cloud-compute/`, verbatim:
> > Access to PCC is available to developers who meet the following criteria:
> > - Are enrolled in the App Store Small Business Program.
> > - Have fewer than 2 million first-time app downloads from any of their apps on the App Store.
> > - Have the Private Cloud Compute entitlement assigned to their account.
>
> …and: *"**Installs during testing are not counted as first-time app downloads.**"* and *"If any app
> subsequently exceeds the 2 million first-time downloads threshold… the developer will be notified
> and must **migrate to an alternative solution within 6 months**."*

Note the **Small Business Program** condition. It appears in **no WWDC transcript we hold** — sessions
241 and 319 both mention only the download threshold. A developer can clear the download bar and
still be ineligible. Note also that the 2M figure is **cumulative/lifetime**, not annual; a developer
on thread 835897 was excluded on the strength of pre-2015 downloads while shipping 180k units in the
last year, and that is the policy working as designed, not a misreading.

⚠️ Use `https://developer.apple.com/private-cloud-compute/` — the
`…/apple-intelligence/private-cloud-compute/` path **404s**.

Three operational facts that bite during migration:

> ✅ **VERIFIED** — Apple Frameworks Engineer, thread **831998**: *"There is a known issue that
> Private Cloud Compute does not currently work in simulators."* Radar **177684296**, documented in
> the iOS 27 release notes, with the workaround *"Use a physical device running OS 27.0."*

> ✅ **VERIFIED** — same thread: **removing the PCC entitlement triggers a `fatalError` at runtime**,
> and `model.isAvailable` can return `true` even when the call subsequently fails.

> ✅ **VERIFIED** — the quota API is coarse. From Apple's PCC article, verbatim:
> ```swift
> if model.quotaUsage.isLimitReached {
>     Text("Usage limit exceeded")
> } else if case .belowLimit(let info) = model.quotaUsage.status {
>     if info.isApproachingLimit {
>         Text("Nearing usage limit")
>     }
> }
> if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
>     Button("Show options") { suggestion.show() }
> }
> ```
> A developer on thread 835974 (FB23378161) asked for actual numbers — *"Am I over 50%, 90%, 99%?"* —
> and the answer is that the API exposes states, not percentages.

**Migration impact:** additive, but treat PCC as an *architecture* decision, not a backend swap. It
introduces a network dependency, a per-user quota with its own UI obligations, and a privacy
boundary that did not exist in your 26.x app. [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) owns
the decision.

### 4.3 ADDITIVE — the `LanguageModel` / `LanguageModelExecutor` protocol pair

This is the structural change of the release. `LanguageModelSession` stopped being "the API for
Apple's on-device model" and became a client for *any* conforming model.

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"we're **opening up our model abstraction layer**…
> built around a **new `LanguageModel` protocol** that allows both local and server models to **back a
> `LanguageModelSession`**. Existing models like **`SystemLanguageModel`** and
> **`PrivateCloudComputeLanguageModel`** already conform to this protocol."* And the value
> proposition, in four words: *"**Everything downstream stays the same.**"*

The protocol text itself:

> ✅ **SDK-verified** — previously reconstructed from a community read plus three independent
> conformances; now confirmed against the captured 27.0 beta interface,
> `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface:1483-1487` and `:1709-1720`
> (2026-07-29). The reconstruction was right, with one member it had left implicit: the executor
> declares `associatedtype Model : LanguageModel` explicitly. `SystemLanguageModel`'s conformance
> is at `:295`.

```swift illustrative
// Verbatim shape from the 27.0 interface (availability: iOS/macOS/visionOS/watchOS 27.0, no tvOS).
public protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model
    var capabilities: LanguageModelCapabilities { get }
    var executorConfiguration: Self.Executor.Configuration { get }
}

public protocol LanguageModelExecutor: Sendable {
    associatedtype Configuration: Hashable, Sendable   // the per-session executor cache KEY
    associatedtype Model: LanguageModel
    func prewarm(model: Self.Model, transcript: Transcript)
    init(configuration: Self.Configuration) throws
    nonisolated(nonsending) func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Self.Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws
}
```

> ✅ **VERIFIED** — the framework index lists, under **Custom Language Model Provider**:
> `LanguageModel`, `LanguageModelCapabilities`, `LanguageModelExecutor`,
> `LanguageModelExecutorGenerationChannel`, `LanguageModelExecutorGenerationRequest` — all
> `iOS 27.0+ Beta`.

**`LanguageModelCapabilities` is load-bearing, not decorative.** Members: `.vision`,
`.guidedGeneration`, `.reasoning`, `.toolCalling` — ✅ **SDK-verified** as the complete public set
(`27.0:1509-1524`), with `LanguageModelCapabilities.init(_:)` current and `init(capabilities:)`
already deprecated-renamed in the same interface (`:1448-1450`). MLX's own doc comment is the
sharpest statement of why they matter:

> ✅ **VERIFIED** — `MLXLanguageModel.swift` doc comment, verbatim: *"Declaring `.reasoning` matters
> for **request routing**: the framework **only forwards a `reasoningLevel` to executors that declare
> `.reasoning`, and auto-rejects one otherwise (on the developer's behalf) before `respond` runs.**"*

Practical consequence for a migrating app: nothing, until you want a second backend. Then the whole
of [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) applies, and the fastest path is often not a
custom conformance at all — see §5.3.

> ⚠️ **The constraint that surprises people.** Grammar-constrained decoding — `@Generable` — needs
> access to engine **logits**. GPU-pipelined Core AI bundles never expose them. So an app that brings
> its own model can **lose Apple's flagship structured-generation feature exactly when it selects the
> fastest backend.** (Community-measured; attribute as such.) If `@Generable` is load-bearing in your
> app, verify it survives before you commit to a backend swap.

### 4.4 ADDITIVE — Dynamic Profiles

> ✅ **VERIFIED** — the framework index group **Dynamic Profiles** contains `DynamicInstructions`,
> `DynamicInstructionsForEach`, `LanguageModelSession.DynamicProfile`,
> `LanguageModelSession.DynamicProfileModifier`, `LanguageModelSession.Profile` — all
> `iOS 27.0+ Beta`. Plus `LanguageModelSession.DynamicProfileBuilder` (a `@resultBuilder`),
> `LanguageModelSession.SessionProperty` (a `@propertyWrapper`), `SessionPropertyKey`,
> `SessionPropertyValues`, and the `SessionPropertyEntry()` macro.

The single most important semantic rule, and the reason this is not just "a config object":

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"**a `DynamicProfile` resolves to a single active
> `Profile` at any given time. You use conditionals to pick which `Profile` is active, and the
> framework handles the transition for you.**"*

Because guides across this series reconstructed this API from spoken narration and got parts of it
wrong, here is the **compiling** version, straight out of Apple's sample:

> ✅ **VERIFIED** — `Origami/Models/OrchestratorProfile.swift`, Apple's Origami sample, verbatim
> (abridged):

```swift prelude:guide-context
struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
    var orchestrator: Orchestrator
    var serverModel = SystemLanguageModel()

    var body: some DynamicProfile {              // NOTE: the SHORT name in the body type
        switch orchestrator.mode {
        case .brainstorm:
            Profile {
                BrainstormInstructions(orchestrator: orchestrator)
            }
            .model(serverModel)                  // a MODIFIER, not an init label
            .temperature(1.0)                    // Double, not Int
        case .tutorial:
            Profile {
                TutorialInstructions(orchestrator: orchestrator)
            }
            .model(SystemLanguageModel())
            .historyTransform(shortHistory(_:))  // ([Transcript.Entry]) -> [Transcript.Entry]
        case .term:
            Profile { TermInstructions(orchestrator: orchestrator) }
                .model(SystemLanguageModel())
                .historyTransform(shortHistory(_:))
        }
    }

    private func shortHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        entries.suffix(4)
    }
}
```

Four corrections that Apple's compiling code forces on any reconstruction:

| Reconstruction in circulation | What the sample actually writes |
|---|---|
| `var body: some LanguageModelSession.DynamicProfile` | **`var body: some DynamicProfile`** — the short name, SwiftUI-style. Conformance stays nested. |
| `Profile(model: x) { … }` | **`Profile { … }.model(x)`** — a modifier. `init(model:)` never appears. |
| `.temperature(1)` | **`.temperature(1.0)`** |
| `.historyTransform { transcript in … }` | **`.historyTransform(f)` where `f: ([Transcript.Entry]) -> [Transcript.Entry]`** — a plain function reference works, and it receives the **entry array**, not a `Transcript`. |

And one initializer nobody's notes had:

> ✅ **VERIFIED** — the sample uses **`LanguageModelSession(profile:history:)`**, passing a
> `Transcript`. The declared parameter is broader than the sample suggests: ✅ **SDK-verified**
> (`27.0:916`) it is `init(profile: sending some DynamicProfile, history: some
> Collection<Transcript.Entry> = [])` — a generic entry collection with an empty default, which a
> `Transcript` satisfies because `Transcript : RandomAccessCollection` (`27.0:2241`). So
> `LanguageModelSession(profile: p)` alone is legal, and so is passing a `Transcript.HistoryView`
> straight from `transcript.history` (an `ArraySlice<Transcript.Entry>` before beta 5 — see §4.9;
> both satisfy the generic). The `history:` label is new; the 26-era `transcript:` label also still
> appears (in the older coffee-game sample). See §7.5.

**Migration impact:** additive. The thing a migrating app should notice is that Dynamic Profiles are
the *supported* replacement for a pattern many teams hand-rolled in 26 — wrapping the session to swap
instructions, tools or models. See §4.9.

### 4.5 ADDITIVE — Skills and history modifiers (the `utilities` package)

These are **not in the OS framework.** They ship in a separate open-source Swift package that Apple
explicitly says updates out of band.

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"we're also releasing a new package, **Foundation
> Models framework utilities**, that will be **updated between OS releases** to give you access to
> **emerging and experimental building blocks**."* Contents as stated: *"**profile modifiers for
> transcript management**, **a skill API for procedural knowledge loading**, and **a language model
> that can interface with servers using the Chat Completions standard.**"*

> ✅ **VERIFIED** — `apple/foundation-models-utilities`, `Package.swift`, platforms:
> `.macOS("27.0")`, `.iOS("27.0")`, `.visionOS("27.0")`, `.watchOS("27.0")`. Swift tools 6.2,
> Swift 6 language mode, **zero external dependencies**. Issues are disabled on GitHub; reporting
> goes to the Developer Forums.

The three history modifiers, applied outside-in:

```swift prelude:guide-context
// ✅ shape verified against the package README and Sources/…/History/*.swift
struct MyProfile: LanguageModelSession.DynamicProfile {
    let status: Status
    var body: some DynamicProfile {
        Profile {
            Instructions("A conversation between a user and a helpful assistant.")
            ToggleDarkModeTool()
        }
        .summarizeHistory(entryThreshold: 10, model: status.summarizerModel)
        .rollingWindow(entries: 10)
        .droppingCompletedToolCalls()
    }
}
```

Apple's own framing, verbatim: *"There's no one-size-fits-all solution, so we encourage composing
strategies together."*

**Skills** are the more interesting migration story, because they encode a KV-cache tradeoff in the
API shape:

| `Skill` initialized with | Content lands in | KV cache | Model priority |
|---|---|---|---|
| `prompt:` | a **tool-output** entry matching the activation tool call (appended) | **preserved** | normal |
| `instructions:` | appended **into the first instructions entry** (rewrites history) | **invalidated** | high |

> ✅ **VERIFIED** — package README, verbatim purpose: *"adding extra directions about performing
> specific tasks into a `LanguageModelSession` transcript on a **just-in-time** basis. This prevents
> **context pollution** and helps optimize **time-to-first-token**."* In both cases **the model
> activates a skill by generating a tool call.**

⚠️ Three package-level gotchas that a migrating team will hit in the first hour:

- **`from: "1.0.0"` resolves to nothing.** The README instructs
  `.package(url: "…/foundation-models-utilities", from: "1.0.0")`, but the only tags that exist are
  `1.0.0-beta1` and `1.0.0-beta3`. SwiftPM's `from:` excludes prereleases. Pin
  `exact: "1.0.0-beta3"` or a revision. ✅ verified against `git ls-remote --tags`.
- **`SkillActivations` no longer conforms to `RandomAccessCollection`** as of beta 3 — replaced by
  `activeSkillNames` and `isActive(_:)`. The README still describes the old shape.
- **The package is explicitly "emerging and experimental"** and moves independently of the OS. Treat
  its API surface as less stable than `FoundationModels` itself.

### 4.6 ADDITIVE — system tools, and the one that isn't where you'd look

Three built-in `Tool` conformances arrived. **Two of them are in the Vision framework, not
FoundationModels**, and that is the single most common wasted hour in adopting them.

> ✅ **VERIFIED** — `BarcodeReaderTool` and `OCRTool` are **`struct`s in the Vision framework**
> (`/documentation/Vision/BarcodeReaderTool`, `/documentation/Vision/OCRTool`), conforming to
> `Sendable, SendableMetatype, FoundationModels.Tool`. Both:
> `init(name: String? = nil, description: String? = nil)`. Availability
> **iOS / iPadOS / macOS / visionOS 27.0+ Beta**.

> ⚠️ **A verified difference with an unverified cause:** `BarcodeReaderTool` **also lists watchOS**;
> `OCRTool` **does not**. Do not smooth this over in a cross-platform build — if you target watchOS
> and reach for OCR, it will not be there.

```swift compile:27
import FoundationModels
import Vision                      // ← the tools live HERE

// ✅ VERIFIED — verbatim from Apple's "Analyzing images with multimodal prompting" article.
func analyzeBarcodeImage(_ image: CGImage) async {
    do {
        let session = LanguageModelSession(tools: [BarcodeReaderTool()])
        let response = try await session.respond {
            """
            Scan this image for any barcodes. For each barcode found, describe \
            its symbology type and explain what the encoded content means or \
            represents.
            """

            Attachment(image)
                .label("barcode-image")
        }.content

        print("The model response: \(response)")
    } catch {
        // Handle the error.
    }
}
```

> ✅ **RESOLVED — SDK-verified 2026-07-29** from the cross-import overlay's own interface, captured
> later the same day (`notes/sdk-interfaces/_Vision_FoundationModels-27.0-macos.swiftinterface`).
> Both tools are declared in the **`_Vision_FoundationModels`** overlay — present in the main
> interface of *neither* parent, materialising only when code imports **both** Vision and
> FoundationModels: `BarcodeReaderTool` (`:14-47`) and `OCRTool` (`:49-83`). The answers:
> - **The whole configuration surface is `init(name: String? = nil, description: String? = nil)`.**
> - **`Arguments`** (both tools) is a nested `Generable` struct with **no named public
>   properties** — its public surface is `generationSchema`, `generatedContent`,
>   `PartiallyGenerated`, and `init(_ content: GeneratedContent) throws`. The model-facing field
>   names exist only in the runtime schema; user code cannot construct one except from
>   `GeneratedContent`.
> - **`Output` is provably unnameable**: it is the opaque return type of
>   `call(arguments:) async throws -> some PromptRepresentable` (`:34-39`, `:70-76`). Write generic
>   code against `PromptRepresentable`; there is nothing to destructure.
> - **No public `Barcode` type exists anywhere in the overlay** — Apple's "array of `Barcode`
>   values" prose describes model-facing content, not a public Swift type.
> - Availability asymmetry, compiler-attested: `BarcodeReaderTool` includes **watchOS 27.0**;
>   `OCRTool` is **watchOS-unavailable**; both are tvOS-unavailable.
> The old safe default — treat both as opaque tools you hand to the session — turns out to be not
> merely safe but the *only* expressible usage.

The third tool surfaces when you import **CoreSpotlight together with FoundationModels**, and is the
one people asked for most. (Precisely where it is declared is subtler than "in FoundationModels":
checked 2026-07-29, `SpotlightSearchTool` appears in **neither** the `FoundationModels-27.0` nor the
`CoreSpotlight-27.0` main module interface we captured — it lives in the
`_CoreSpotlight_FoundationModels` cross-import overlay, the module
[guide 17.4](04-dual-sdk-builds.md) names, which materialises only when both frameworks are
imported. That overlay's interface is now captured too:
`notes/sdk-interfaces/_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface`, with the tool's
full configuration surface — see [guide 2.4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md).)

> ✅ **VERIFIED** — Apple's hiking-trails sample uses
> `SpotlightSearchTool(configuration: .init(sources: [.coreSpotlight(.init(searchableIndexDelegate:fetchAttributes:))], guide: .focused()))`.
> The model-facing tool name is **`spotlight_search`** (snake_case). **No entitlement is required** —
> the sample's `.entitlements` is an empty `<dict/>`. `tool.searchResults` is an `AsyncSequence` whose
> `.content` is a **7-case non-frozen** enum.

⚠️ Two live defects to know about before you build a feature on it:

- **The description/schema mismatch.** The human-readable `description` presents top-level arguments
  as `{ root, modelComposition, … }` while the `parameters` JSON Schema requires
  `{ "query": { "type": "search", "value": { … } } }`. A model that follows the description is
  guaranteed to fail the schema. **DTS confirmed this is a known issue** (threads 832534 / 833651).
  Practical effect: the tool is effectively uninvokable by any non-Apple model.
- **`Model Catalog error … com.apple.UnifiedAssetFramework Code=5000`** on a bare
  `SpotlightSearchTool()` even when the model reports available (thread 838904). Apple Designer's
  reply, verbatim: *"Whelp, that's totally a bug. 🐛 You're doing everything correctly!"* The reporter
  says rebooting did **not** fix it and it persisted across two betas.

[Part 2 guide 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md) owns the working recipe.

### 4.7 ADDITIVE — `usage` on sessions and responses

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"**Sessions and responses now have a `usage`
> property that tells you precisely how many tokens were used. You can also check how many of the
> input tokens were read from cache, and how many of the response tokens were used for reasoning.**"*

> ✅ **VERIFIED** — `/documentation/foundationmodels/…`, and now ✅ **SDK-verified**
> (`27.0:1980-2017`, re-checked 2026-08-23), the shape:
> ```swift
> struct LanguageModelSession.Usage              // iOS 27
> init(input:output:metadata:)
> var input: Usage.Input        // .totalTokenCount, .cachedTokenCount
> var output: Usage.Output      // .totalTokenCount, .reasoningTokenCount
> var metadata: [String: GeneratedContent]   // beta 5; was [String: any Sendable]
> var totalTokenCount: Int
> ```
> `Response`, `ResponseStream.Snapshot` and `LanguageModelSession` all expose `.usage`
> (`session.usage` at `27.0:1936-1938`).
> The KV-caching article gives the derived metric: *"determine your cache hit rate by dividing the
> cached input tokens by the total input tokens."*

**Migration impact:** additive, and the cheapest instrumentation win in the whole release. If you are
migrating anything cost- or latency-sensitive, wire this up first — it gives you a number to compare
before and after.

### 4.8 ADDITIVE — `toolCallingMode`, and its exit-condition trap

> ✅ **VERIFIED** — `GenerationOptions.ToolCallingMode`, `iOS 27.0+ Beta`:
> ```swift
> struct ToolCallingMode         // Equatable, Sendable, SendableMetatype
> static var allowed             // "The model may or may not call tools."
> static var disallowed          // "The model may not call any tool."
> static var required            // "The model must call one or multiple tools."
> var kind: GenerationOptions.ToolCallingMode.Kind
> ```

> ⚠️ **SILENT FAILURE — an infinite tool-call loop.** Apple states this verbatim on **both** the
> `ToolCallingMode` page and the tool-calling article: *"When you set the mode to `required`, you must
> define an exit condition by either throwing an error from a tool's `call(arguments:)` method or by
> changing the mode dynamically using a `LanguageModelSession.DynamicProfile`; **otherwise, the model
> continues to call the tool.**"* There is no automatic loop breaker. You will observe this as a
> session that never returns.

Apple's documented escape pattern, which doubles as the canonical `@SessionProperty` example:

```swift prelude:guide-context
// ✅ VERIFIED — verbatim from Apple's ToolCallingMode documentation.
extension SessionPropertyValues {
    @SessionPropertyEntry
    var toolCallCount: Int = 0
}

struct RecipeDynamicProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.toolCallCount)
    var toolCallCount

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            BreadDatabaseTool()
        }
        .toolCallingMode(toolCallCount < 1 ? .required : .allowed)
        .onToolCall {
            toolCallCount += 1
        }
    }
}
```

> ⚠️ **Two surfaces for one concept.** `toolCallingMode` exists **both** as
> `GenerationOptions(toolCallingMode:)` (per request) and as a `DynamicProfile.toolCallingMode(_:)`
> modifier. An Apple Frameworks Engineer recommended the profile form on thread 833692
> (*"You can use `.toolCallingMode` with `DynamicProfiles` for this."*), while developers in the wild
> use the `GenerationOptions` form. The same-type half of this is now settled: ✅ **SDK-verified**
> (`27.0:978`), the profile modifier takes exactly `GenerationOptions.ToolCallingMode?` — one type,
> two surfaces. Which wins is settled in **one direction only**. ✅ **Device-verified 2026-08-20**
> (iPhone 15 Pro, iOS build `24A5408d`): with the profile allowing the tool and call-site options
> `.disallowed`, the tool was **not** called — call-site options override the profile in the
> profile-allows → options-disallow direction. 🟡 The reverse direction
> (profile-disallows → options-require) is **not a recorded observation**: that run threw
> `LanguageModelError.contextSizeExceeded(4096, 4099)`, and the probe's catch path did not record
> the `toolCalled`/`toolRan` discriminators, so "the tool loop ran" there is an inference from the
> error fingerprint, not a measurement. The probe has been updated to record the discriminators on
> the next device run. Until then, treat options-over-profile as confirmed for *disallowing* and
> unproven for *requiring* — and still pick one surface per feature unless an intentional per-turn
> override is clearer.

> ⚠️ **Initializer footgun.** In the iOS 27 four-argument `GenerationOptions` initializer,
> `toolCallingMode` has **no default value** while `samplingMode`, `temperature` and
> `maximumResponseTokens` do. So `GenerationOptions(toolCallingMode: .required)` compiles, but you
> cannot omit `toolCallingMode` and still select that overload. ✅ verified from the declaration.

### 4.9 ADDITIVE — a mutable transcript, and `Transcript.history`

If your 26.x app hand-rolled context compaction, this is the item that obsoletes your code.

> ✅ **VERIFIED** — Apple Frameworks Engineer, Developer Forums thread **835927**, verbatim:
> *"The way you're doing compaction is generally correct, and recreating the session with the new
> transcript is correct if you're targeting **iOS 26**. In **iOS 27**, session's `transcript` property
> is now **mutable**, and transcript has a **`history` accessor** for updating everything except the
> instructions, so you can just use that instead of recreating the session. We've also introduced the
> notion of **`DynamicProfiles`**… and open sourced some context management utilities similar to your
> own!"*

> ✅ **VERIFIED** — the declarations, now also ✅ **SDK-verified** (beta 5 recapture):
> ```swift
> final var transcript: Transcript { get set }                    // settable — 27.0:1912-1917
> var history: Transcript.HistoryView { get set }                 // iOS 27 — 27.0:2695-2700
> var structuredTranscript: StructuredTranscript { get }          // iOS 27 — see below
> ```
> `Transcript.structuredTranscript`'s availability line notably **omits Mac Catalyst** — and the
> interfaces explain why it is odd generally: it is **not in FoundationModels at all**. It is
> declared in the **Evaluations** module, as an `extension FoundationModels.Transcript` returning
> `Evaluations.StructuredTranscript` (`Evaluations-27.0-macos.swiftinterface:286-292`; grep-0 in
> the FoundationModels dump). You need `import Evaluations` to see it, which also means it exists
> only where the Xcode-shipped Evaluations framework does.

> ⚠️ **CHANGED in Xcode 27 beta 5 (noted 2026-08-23).** In the 2026-07-29 beta capture,
> `Transcript.history` — and the `SessionPropertyValues.history` session property with it — was typed
> **`ArraySlice<Transcript.Entry>`**. The beta 5 interface retypes both as the new nested collection
> **`Transcript.HistoryView`** (`27.0:2695-2700`; the session property at `27.0:1071-1076`).
> ✅ **SDK-verified** (`27.0:2667-2694`): `HistoryView` is a `MutableCollection` +
> `RandomAccessCollection` + `RangeReplaceableCollection` + `Sendable` struct with
> `Element == Transcript.Entry`, and it is **its own `SubSequence`** (`27.0:2669`), so slice-shaped
> code like `history = history.suffix(50)` still type-checks. What breaks: its `Index` is an opaque
> `Transcript.HistoryView.Index` struct (`27.0:2703-2718`), **not `Int`** as `ArraySlice`'s was, so
> integer subscripts (`history[0]`) no longer compile — use `first`/`last` or index arithmetic — and
> any stored property, signature, or cast written against `ArraySlice<Transcript.Entry>` must be
> retyped. The new type also gains `append(_:)` / `append(contentsOf:)` (`27.0:2686-2687`) and
> array-literal construction (`27.0:2719-2724`). No 26.x code is affected — the whole surface is
> 27-only either way.

⚠️ Mutating a transcript has a new failure mode attached to it:
`LanguageModelSession.Error.transcriptMutationWhileResponding` — *"The session's transcript was
mutated while a request was in progress."* See §7.1.

### 4.10 ADDITIVE — `TranscriptErrorHandlingPolicy`

New, small, and directly relevant to anyone who has tools that throw.

> ✅ **VERIFIED** — `/documentation/foundationmodels/transcripterrorhandlingpolicy`:
> ```swift
> struct TranscriptErrorHandlingPolicy   // Sendable, SendableMetatype
> static let preserveTranscript   // "Keep the current transcript as is."
> static let revertTranscript     // "Revert the transcript back to the state it was in
>                                 //  just before the most recent request."
> ```
> And from the tool-calling article, verbatim: *"When errors are thrown from a tool, the framework
> rolls back the transcript to a previously known valid state. Use `transcriptErrorHandlingPolicy` to
> define whether the session preserves the transcript an error occurs or if it reverts back to before
> the last request. **When preserving the transcript, the last entry may be partially generated.**"*

That last sentence is the trap. `.preserveTranscript` can leave you holding a **half-generated
entry**, which will then be fed back to the model on the next turn. If you preserve, validate.

> ✅ **Probe-verified, 2026-07-31 — the default is `nil`, and `nil` behaves like
> `.revertTranscript`.** (was 🟡 RECONSTRUCTED; `probes/` `fm.transcript-policy-nil-default`, run
> on the 27.0 sim runtime.) The session property's initial value is `nil`, and after a failed
> request the `nil` transcript outcome **matches `.revertTranscript`** — both rolled back to just
> the instructions entry — while `.preserveTranscript` retained the prompt entry. The old
> reconstruction was right, and the probe confirmed it. Setting the policy explicitly is still good
> manners for the next reader, but relying on the implicit rollback is now measured behaviour, not
> a guess.

```swift illustrative
// ✅ SDK-verified — both spellings are real and canonical (27.0:982 and 27.0:1925-1932).
// As a DynamicProfile modifier:
Profile { … }.transcriptErrorHandlingPolicy(.preserveTranscript)

// As a settable session property:
session.transcriptErrorHandlingPolicy = .preserveTranscript
```

### 4.11 ADDITIVE — `ContextOptions` and reasoning levels

> ✅ **VERIFIED** — `ContextOptions`, `iOS 27.0+ Beta`; now also ✅ **SDK-verified**
> (`27.0:3130-3146`), where both stored properties turn out to be **Optionals**:
> ```swift
> struct ContextOptions : Sendable, Equatable
> init(includeSchemaInPrompt: Bool? = nil, reasoningLevel: ReasoningLevel? = nil)
> var includeSchemaInPrompt: Bool?   // "Inject the schema into the prompt to bias the model."
> var reasoningLevel: ContextOptions.ReasoningLevel?
>
> enum ReasoningLevel : Sendable, Equatable
> case light           // "…good for quick responses."
> case moderate        // "…a moderate amount thinking."
> case deep            // "…good for more analysis over a request."
> case custom(String)  // "A custom level that indicates a level not supported by the other cases."
> ```

Call site, verbatim from Apple's PCC article:

```swift prelude:guide-context
let response = try await session.respond(
    to: "What are the tradeoffs in this architecture?",
    contextOptions: ContextOptions(reasoningLevel: .deep)
)
```

Apple's guidance, verbatim: *"start with `.moderate`. Use `.deep` when you determine the task needs
additional reasoning… Deep reasoning is slower, but it spends more time catching things that the
other levels miss."* And the budget consequence: *"The more reasoning you apply causes the model to
use more of the context window… **Reasoning segments reflect the model's intermediate reasoning and
don't appear in the final response content.**"*

Note that `includeSchemaInPrompt` — a 26-era parameter on `respond`/`streamResponse` — now *also*
lives on `ContextOptions`. The 27.0 interface shows the duplication plainly: the 26-era
`includeSchemaInPrompt: Bool = true` overloads survive un-deprecated (`27.0:2103-2123`) alongside
new `contextOptions:` overloads whose default is `ContextOptions(includeSchemaInPrompt: true)`
(`27.0:2129-2177`) — they are **separate overload families**, so a single call cannot actually pass
both. ✅ **Probe-verified, 2026-07-31 — they are one knob with two spellings, and mixing them is
harmless.** (was a 🔴 GAP; `probes/` `fm.includeSchemaInPrompt-recording`, run on the 27.0 sim
runtime.) The legacy `includeSchemaInPrompt: false` parameter and
`ContextOptions(includeSchemaInPrompt: false)` are recorded **identically** on
`Transcript.Prompt.contextOptions` — same `ContextOptions(includeSchemaInPrompt: Optional(false))`
entry either way — and an all-defaults call records `Optional(true)`. There is no second
independent setting to disagree with the first, so the "mixing families across a session" fear
dissolves; alternating spellings between calls just writes the same field. Only the
profile-supplies-one-while-the-call-supplies-the-other precedence remains unmeasured, as with
every profile-vs-call knob. Style still favours one spelling per codebase — the new one.

### 4.12 ADDITIVE — watchOS

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"**Private Cloud Compute makes it possible for us
> to bring the Foundation Models framework to watchOS**. Starting in **watchOS 27**, you can wear your
> most powerful intelligence features right on your wrist."*

The availability strings tell the real story: a large set of 26.0 symbols (`LanguageModelSession`,
`Transcript`, `Tool`, `Generable`, `Prompt`, `GenerationOptions`, `Response`, …) carry
`iOS 26.0+, … visionOS 26.0+, watchOS 27.0+ Beta` — i.e. **they gained watchOS in 27**. But
`SystemLanguageModel` itself, `SystemLanguageModel.Availability`, `SystemLanguageModel.Guardrails`,
`SystemLanguageModel.Error`, `LanguageModelSession.GenerationError` and
`LanguageModelSession.ToolCallError` **do not list watchOS at all**.

Read that as: **on watchOS the framework is a PCC surface.** The on-device model is not described as
running on the watch anywhere we can find.

> 🟡 **RECONSTRUCTED / community** — a forum poster (thread 834652) self-answered that a Series 11
> watch on watchOS 27 **also needs to be paired to an iPhone with Apple Intelligence enabled**, even
> though PCC queries go straight to the server. **No Apple reply.** If watchOS is in your migration
> scope, verify this yourself before it becomes a support burden.

⚠️ See §10 for the watchOS 27 beta 2 build break, which Apple confirmed as a known bug.

---

## 5. ADDITIVE — beyond Foundation Models

### 5.1 ADDITIVE — the Evaluations framework (Xcode 27)

> ✅ **VERIFIED** — WWDC26 session 334, verbatim: *"Swift developers can leverage the **Evaluations
> framework**. It's **available with Xcode 27**, and it makes it easy to create evaluations, and
> **track the accuracy of your features across multiple iterations**."*

> ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread 833729, accepted: *"Evaluations is a
> Swift-based framework. So you would need to call the Swift APIs from the other language."* —
> i.e. **Swift only**.

This is the framework that exists because §3.1 is true. Apple's own recommended use of it is
**regression testing across OS updates**, precisely because there is no model version pinning.

For a migrating app, the sequence that actually works is:

1. Wire up an evaluation **against your current 26.x behaviour** before you change anything.
2. Capture a dataset of real prompts and the outputs you consider correct.
3. Re-run it on 27. The diff is your migration risk, quantified.

Apple's Book Tracker sample is the full worked ladder — `#Playground` → heuristic evaluators → a
model judge → generated samples → **κ-calibration of the judge** → `.evaluates(info:)` for diffable
runs.

> ⚠️ **One correction worth carrying:** the sample calibrates its model judge against human labels
> using Cohen's κ (threshold κ > 0.6), but **the framework does not ship an agreement statistic.**
> `Statistics.cohensKappa` is **72 lines of hand-rolled Swift in the sample.** ✅ verified against the
> archive. Don't plan around a built-in you'd have to write.

> ⚠️ The Evaluations **forum topic contains three threads, total**, all from WWDC26 week, one
> unanswered. There is essentially no community knowledge here yet. Budget accordingly.

[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) owns this.

### 5.2 ADDITIVE — the `fm` command-line tool (macOS 27)

> ✅ **VERIFIED** — WWDC26 session 334, verbatim: *"The `fm` command line tool **comes pre-installed
> with macOS 27**… It makes it really easy to **test the model with some prompts without rebuilding
> your project in Xcode**."*

Subcommands named on screen: `fm respond`, `fm chat`, `fm schema` (and `fm schema object`), plus
"and more". The beta-era session demonstrated `/model` (switch the live conversation to PCC) and
`/save`; stable interactive slash commands remain untested. Bare `fm` prints the command list.

> ✅ **RESOLVED 2026-08-17** (was 🟡 RECONSTRUCTED) — the **flag spellings**. The presenter only ever
> named *"the model option"*, *"the image option"*, *"the schema option"*, *"the help option"*; the
> spellings are now captured from the tool itself, run on macOS 27 beta 5 (`26A5406e`):
> `notes/sdk-interfaces/fm-help-27.0.txt`, including the short forms (`-m`, `-i`, `-g`, `-v`, `-h`).

> ✅ **RESOLVED 2026-08-17** (was 🔴 GAP — *"the single largest hole in the `fm` story"*) —
> **`fm schema object`'s argument grammar, and the full subcommand list, are captured.** `/usr/bin/fm`
> was run by this project on macOS 27 beta 5 (`26A5406e`); `fm --help` plus every revealed help page
> is preserved as `notes/sdk-interfaces/fm-help-27.0.txt` under the SDK evidence manifest. The eight
> top-level commands are `available`, `chat`, `count-tokens`, `license`, `quota-usage`, `respond`,
> `schema`, and `serve`, and `schema object` supports boolean/double/integer/string properties,
> nested objects, `anyOf`, arrays, descriptions, and optionality.
> [Part 5 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)
> owns the full capture; the runtime-only residue (interactive slash commands, refusal/error exits,
> field-level `serve` compatibility) is tracked there and in §14.8 row 7.

> ⚠️ **STABLE-SURFACE UPDATE, 2026-09-16.** Stable macOS 27 has a smaller surface and advertises
> only the `system` model. The canonical beta-versus-stable comparison is
> [5.2 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27).
> Keep the beta capture as historical evidence and re-run `fm --help` on the deployment OS before
> using it in migration automation.

**Migration relevance:** stable `fm` is the fastest way to exercise the on-device system model
without touching your project. Use Swift for PCC comparison unless a later stable CLI advertises
that model again.

### 5.3 ADDITIVE — `ChatCompletionsLanguageModel` turns your existing stack into a backend

This one deserves separate billing because it changes the migration calculus for anyone who was
about to write a custom `LanguageModel` conformance.

> ✅ **VERIFIED** — `apple/foundation-models-utilities`, `Sources/FoundationModelsUtilities/
> LanguageModels/ChatCompletionsLanguageModel.swift`, and the package README:

```swift prelude:guide-context
let model = ChatCompletionsLanguageModel(
    name: "some-model-id",
    url: URL(string: "http://localhost:8000/v1")!,
    supportsGuidedGeneration: false   // some local servers don't support it
)
let session = LanguageModelSession(model: model)
```

That means `mlx_lm.server`, Ollama, vLLM and LM Studio become Foundation Models backends **today**,
without waiting for anything. Note that **capability declaration is a real, user-visible part of the
protocol** — `supportsGuidedGeneration: false` is you telling the framework what not to ask for.

> ⚠️ **Known defect, confirmed and accepted by Apple, not yet fixed.** The private
> `buildURLRequest(for:)` decides versioning with a literal string test:
> ```swift
> let isVersioned = baseURL.pathComponents.contains("v1")
> let endpoint = isVersioned ? "/chat/completions" : "/v1/chat/completions"
> ```
> Any provider not on `/v1` gets a mangled URL (a real report: `/api/v3/responses/v1/chat/completions`
> → HTTP 404). The reporter's fix — a regex over `v\d+` — was accepted by Apple with *"Fantastic
> suggestion, thanks! We're on it."* (thread 838444, FB23837262), but as of the commit we read it is
> **still present**. There is no escape hatch. ✅ verified in source at `1.0.0-beta3`.

> ⚠️ Also note the README's own example URL is malformed: `http://localhost/v1:8000`. Don't
> copy-paste it.

### 5.4 ADDITIVE — Core AI

Core AI is not a migration of anything; it is a brand-new framework, and it is **27.0 and only 27.0**
on every platform, every symbol flagged Beta. There is no 26.x back-deployment story.

> ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread 833657, accepted answer, verbatim:
> *"All on-device Apple Foundation Models are powered by Core AI."*
> (The follow-up question — whether AFM 3 Core can be opened in the Core AI Debugger — was **not**
> answered.)

> ⚠️ **Core AI ships with zero Apple sample-code projects.** Verified this cycle: 0 `sampleCode`
> entries across all indexed Core AI symbols. Unlike Foundation Models, there is no first-party
> compiling reference to read. Budget for that.

Two things a migrating team needs to know now, both owned elsewhere:

- **Core AI is the successor path for *neural networks*.** Core ML remains correct for decision
  trees, tabular feature engineering, and the rest of its non-neural surface. This is a **partial**
  migration by design. → [guide 17.5](05-coreml-to-coreai.md).
- **`.aimodel` is portable source, not executable.** It must be *specialized* per device **and per
  OS version** before it runs, which is why an OS update invalidates caches and can make a saved
  bookmark stop resolving. → [Part 7 guide 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).

> ⚠️ **Never write `.coreaimodel` or `.aiasset`.** Both extensions are fabricated and both are in
> circulation. The real extensions are **`.aimodel`** (portable source, a *directory*) and
> **`.aimodelc`** (per-architecture AOT-compiled, also a directory). There is likewise **no
> `coreai-torch convert` CLI** — the conversion entry points are the `coreai-torch` Python package
> and `xcrun coreai-build compile` for AOT. Part 1 carries the full known-bad-claims list.

### 5.5 ADDITIVE — the framework is going open source

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"In addition to the utilities package, **the core
> of the FoundationModels framework will also be open source.** Open sourcing the Foundation Models
> framework makes it a great solution for interacting with LLMs everywhere Swift runs, **including
> Linux servers**."*

> 🔴 **GAP** — **as of 2026-07-29 no standalone repository for the core framework exists.** A search
> across `apple/*` and `swiftlang/*` found only `foundation-models-utilities`, `python-apple-fm-sdk`
> and `coreai-models` (re-run via `gh search repos` on 2026-07-29 — unchanged). The core framework
> still appears to ship only in the OS/SDK.
> What would resolve it: the repository appearing, or an Apple statement of timing.
> **Safe default:** do not plan a Linux deployment on the strength of this announcement. The
> `utilities` package's own README claims *"Apple platforms and select Linux distributions like
> Ubuntu"* — but the package has **no CI, no `.github/`, no Dockerfile and no build matrix**, so that
> claim is untested even within Apple's own repo. ✅ verified by inspection of the clone.

---

## 6. BEHAVIOURAL — the category where your diff is empty

Everything above this line is optional. Everything below it happens to you whether you opt in or not.

The defining property of this section: **your source does not change, your build succeeds, your tests
(if they only assert types) pass, and your app behaves differently in production.** Work through all
of it before you adopt a single additive feature.

### 6.1 BEHAVIOURAL — the on-device model was rebuilt

Covered in §3, restated here because it is the root cause of most of the rest.

Between the release you shipped and the release your users receive, the model changed **twice**
(26.4 and 27.0), and Apple describes the 27 model as *"rebuilt from the ground up."* Prompts tuned
against 26.x — especially few-shot examples, ALL-CAPS constraint phrasings, and instructions that
lean on a particular failure mode — are tuned against a model that no longer exists on updated
devices.

**What this looks like in the field:** output length changes, formatting drifts, a tool that used to
be called reliably stops being called, or a `@Generable` field that used to populate comes back
empty. None of it throws.

**What to do, in order:**

1. **Get a baseline before you upgrade anything.** If you still have a device on 26.x, capture
   real outputs for your top 20 prompts now. Once every device in your fleet is on 27 you cannot
   reconstruct this.
2. **Re-test every prompt.** Apple's release notes tell you to, twice, in the same words (§3).
3. **Watch the token budget.** The model changed; the *tokenisation* of your prompt may have too.
   Read `contextSize` and use `tokenCount(for:)` rather than an old measured number.
4. **Expect the `#Playground` numbers to have moved.** The 26.4 release notes mention the canvas
   showing an estimate against **4,096 tokens** with **Input Token Count** and **Response Token
   Count** shown separately — a useful, cheap comparison point.

> ⚠️ Apple's own empirical result is worth internalising here, because it contradicts the intuitive
> fix. From WWDC26 session 334's Python case study, verbatim: *"the **detailed prompt leads to a high
> percentage of generation errors**. **This can happen, for example, when we reach the model's max
> context window size.**"* and *"the two less detailed prompts tend to lead to **excess items**…
> however, with the more detailed prompts, we tend to **miss more items that were expected**"* and
> *"The **first prompt also tends to lead to more hallucinated items**."*
> **There is no monotone "more prompt = better."** Rewriting a regressed prompt to be longer and more
> rule-heavy trades precision for recall *and* raises your context-overflow rate.

### 6.2 BEHAVIOURAL — guardrails changed, twice

> ✅ **VERIFIED** — WWDC26 session 241, verbatim: *"You may have noticed adjustments in **iOS 26.4 to
> reduce the number of false positives**, and we're continuing to make even more improvements in
> iOS 27."*

> ✅ **VERIFIED** — the 26.4 release notes entry, verbatim: *"Reduce the possibility of blocking
> benign content with improved guardrails for `SystemLanguageModel`."*

"Fewer false positives" sounds unambiguously good. In practice it means **the boundary moved**, and a
moved boundary breaks apps in both directions: content that used to be blocked may now pass (and your
downstream code has never seen it), and — as §6.3 shows — traffic can shift between two *different*
refusal mechanisms with different error types.

Real, documented trigger words from developer reports across this period: *"kill"*, *"frunk"*,
*"Pride"* (a car's name), *"luteal phase"*, *"progesterone"*, *"glucose"*, *"time in range"*,
*"diabetes"*, and — memorably — *"taco recipe"*. A digital-wellbeing app was blocked on exactly its
safety-critical path: asking the model whether a user is in deep distress, in order to show crisis
support resources (FB20828230).

The one knob you have:

> ✅ **VERIFIED** — `SystemLanguageModel.Guardrails` has exactly two documented statics:
> `.default` and `.permissiveContentTransformations`. Usage appears in a shipping Apple sample:
> `SystemLanguageModel(guardrails: .permissiveContentTransformations)`.

> ⚠️ **SILENT FAILURE — the knob does not do what most people assume.** Apple's own safety article,
> verbatim: *"**This mode only works for generating a string value.** When you use guided generation,
> the framework runs the default guardrails against model input and output as usual, and generates
> `guardrailViolation` and `refusal` errors as usual."* And: *"even with the `SystemLanguageModel`
> guardrails off, the on-device system language model still has a layer of safety. For some content,
> **the model may still produce a refusal message**."*
>
> So: if your feature uses `@Generable` — and most do — **`.permissiveContentTransformations` buys
> you nothing.** Developers have independently rediscovered this on the forums for over a year. It
> does not throw, does not warn, and looks like it's working right up until you test a sensitive
> input.

Guide [17.3](03-error-taxonomy-migration.md) owns the full treatment, including the regression-test
recipe.

### 6.3 BEHAVIOURAL — refusal traffic moved between two mechanisms

This is the most commercially dangerous item in the whole migration, and it is **unresolved**.

> ✅ **VERIFIED** — Developer Forums thread **836673**, *"Foundation Models: Model-level refusal
> regression on iOS 27 beta for health app prompts (not guardrailViolation)"*. A shipping health app
> that summarises the user's **own** glucose and menstrual-cycle data worked on iOS 26.x from early
> 2026, then **every prompt was refused on iOS 27 beta 2**.
>
> The reporter's key finding: the error is a **`LanguageModelError`** — *"The model refused to
> answer" / "May contain sensitive content"* — and **not**
> `GenerationError.guardrailViolation`. Their characterisation:
> *"Classifier passes, but model itself refuses."* Filed **FB23513774**. Corroborated by a second
> developer (a journaling app) on iOS 27 beta. **No Apple reply as of capture.**

Two mechanisms exist and they are not the same thing:

| Mechanism | Where it lives | Error surface | Affected by `guardrails:` |
|---|---|---|---|
| **Guardrail violation** | a classifier around the model, on input and output | `LanguageModelError.guardrailViolation` (27) / `GenerationError.guardrailViolation` (26) | Yes — that's what the knob is for |
| **Model-level refusal** | the model itself, downstream of the classifier | `LanguageModelError.refusal` (27) / `GenerationError.refusal` (26) | **No.** `.permissiveContentTransformations` does not help. |

And there is a third shape that is not an error at all:

> ✅ **VERIFIED** — Apple's safety article, verbatim: *"When you generate a **string** response, and
> the model refuses a request, **it generates a message that begins with a refusal like 'Sorry, I
> can't help with'**. **You might not be able to programmatically determine whether a string response
> is a normal response or a refusal**… When you use guided generation to generate Swift structures or
> types, **there's no placeholder for a refusal message. Instead, the model throws** a refusal error."*

> ⚠️ **SILENT FAILURE.** A string-generating feature that gets refused **returns a successful
> response containing an apology.** No error, no exception, no signal. If your app writes that string
> to a database, emails it, or shows it as a summary, you have shipped an apology as data. Apple's own
> suggested workaround is to spin up a **second session and ask the model to classify whether the
> string is a refusal** — which tells you how little structural signal there is.

**Migration action:** if your feature touches health, finance, legal, personal safety or any
regulated domain, treat re-testing on 27 as a release blocker rather than a task. Cross-link
[guide 17.3](03-error-taxonomy-migration.md).

### 6.4 BEHAVIOURAL — Apple's samples dropped proactive availability gating

This is a change in *guidance*, not in API, and it is the kind of change that quietly propagates into
codebases because people copy samples.

**What the 26-era sample does** — the one availability switch in any of the five archives we hold:

> ✅ **VERIFIED** — `FoundationModelsCoffeeGame/MainMenu/MainMenuView.swift`, an **iOS 26** sample
> (`IPHONEOS_DEPLOYMENT_TARGET = 26.0`), verbatim:

```swift prelude:guide-context
switch SystemLanguageModel.default.availability {
case .available:
    gameStartButton
case .unavailable(let reason):
    switch reason {
    case .appleIntelligenceNotEnabled:
        Text("To play this game, turn on Apple Intelligence in Settings.")
    case .modelNotReady:
        Text("Cannot start the game until model is ready to use. Come back later!")
    case .deviceNotEligible:
        Text(":( Sorry, this game needs a device compatible with Apple Intelligence.")
    default:
        Text(":( Sorry, cannot start game. The model is unavailable for unknown reasons.")
    }
}
```

**What the 2026 samples do:** nothing of the kind.

> ✅ **VERIFIED** — Apple's Origami sample (iOS 27) **never calls `SystemLanguageModel.availability`,
> never calls `.isAvailable`, and never gates UI on model readiness.** It relies entirely on catching
> `SystemLanguageModel.Error` at use time and mapping it to display copy:

```swift compile:27 imports:FoundationModels
// ✅ VERIFIED — Origami/Models/Error+DisplayMessage.swift, verbatim.
extension Error {
    /// A short message describing the error, suitable for display in the UI.
    var displayMessage: String {
        if self is SystemLanguageModel.Error {
            return "Apple Intelligence isn't available right now."
        }
        if let modelError = self as? LanguageModelError {
            switch modelError {
            case .timeout:
                return "This is taking longer than expected. Please try again."
            case .guardrailViolation, .refusal:
                return "Origami can't work with that. Try a different photo or prompt."
            case .contextSizeExceeded:
                return "There's too much in this conversation. Try regenerating to start fresh."
            case .unsupportedLanguageOrLocale:
                return "Origami doesn't support this language."
            default:
                break
            }
        }
        if self is GeneratedContent.ParsingError {
            return "Origami had trouble understanding the response. Please try again."
        }
        return "Something went wrong. Please try again."
    }
}
```

Note the ordering: **`SystemLanguageModel.Error` is checked *first*, before `LanguageModelError`.**
Availability failures are a *different type* from generation failures and do **not** appear as a
`LanguageModelError` case. Note also `default: break` — `LanguageModelError` is **non-frozen**.

> ✅ **VERIFIED** — the Spotlight sample ships a near-identical `Error+DisplayMessage.swift` (minus
> the `ParsingError` clause). **Two independent samples agreeing on those five case names is the
> strongest confirmation available short of the headers.**

> ⚠️ **SILENT FAILURE — do not just copy the new pattern.** Reactive-only gating means the user
> discovers Apple Intelligence is unavailable **after** they tap the button, after your spinner, and
> possibly after they paid. Apple's *own* guidance on the forums contradicts its own samples here:
>
> > ✅ **VERIFIED** — Apple Designer (Apple), thread 836810, verbatim: *"Run an availability check as
> > soon as you launch your app… From a UX standpoint, **try to check availability before anyone
> > agrees to pay for your app's service**, to avoid someone paying for what they can't use."*
>
> **Teach and ship both.** Gate proactively so the UI is honest; catch reactively so you handle the
> races (model downloading, user toggling Apple Intelligence off mid-session, a device that becomes
> ineligible after an OS update). The Origami posture is defensible only because its deployment
> target is 27.0 and its whole reason for existing is to demonstrate profiles.

Here is the both-belts version, written against the verified case names:

```swift prelude:guide-context
import FoundationModels
import SwiftUI

struct IntelligenceGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    // Proactive: what the 26-era sample did, and what Apple's forum guidance still says.
    // ✅ Availability enum verified: .available / .unavailable(reason) with
    //    .appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady.
    var body: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            content()
        case .unavailable(.deviceNotEligible):
            Text("This feature needs a device that supports Apple Intelligence.")
        case .unavailable(.modelNotReady):
            Text("Getting things ready — check back shortly.")
        case .unavailable(let other):
            // Includes .appleIntelligenceNotEnabled. See §6.5 before you write
            // "turn on Apple Intelligence" copy that mentions Siri.
            Text("Apple Intelligence isn't available right now. (\(String(describing: other)))")
        }
    }
}

// Reactive: what the 2026 samples do. You need this as well, not instead.
func summarize(_ text: String) async -> String {
    do {
        let session = LanguageModelSession()
        return try await session.respond(to: "Summarize: \(text)").content
    } catch {
        return error.displayMessage      // the extension above
    }
}
```

> ⚠️ **A second silent failure hiding in the same samples.** Origami's free-text stream consumption
> guards against a stream that finishes having yielded **zero partials** — which happens when the
> model emits **only a tool call**:
> ```swift
> // ✅ VERIFIED — Coach/CoachModel.swift, Apple's Origami sample, verbatim comment:
> // If the stream finished without ever yielding text (for example, the model
> // only returned a tool call), land on `.responded("")` so the UI
> // exits the loading state and the follow-up field returns.
> if !didReceivePartial {
>     state = .responded("")
> }
> ```
> Any "spinner until first token" UI written in 26 and carried into 27 **hangs forever** in that case.
> If you adopt tools, audit every streaming UI for this.

### 6.5 BEHAVIOURAL — the Siri-enablement gate is a DEFECT, not a design

Read this section before you write a single line of "turn on Apple Intelligence" UX.

**The symptom is real and you will hit it.**

> ✅ **VERIFIED** — Developer Forums thread **835211** (iOS 27 beta 1, unanswered): the user must
> enable *"Siri"/"Hey Siri"* or *"Press Side Button for Siri"* in Settings for
> `SystemLanguageModel.default.availability` to report available; otherwise it returns
> **`.appleIntelligenceNotEnabled`**. Thread **836760** reports the same on macOS since beta 2,
> with an explicit EU-availability concern.

**But it is not the intended behaviour, and Apple said so.**

> ✅ **VERIFIED** — **Apple Frameworks Engineer**, Developer Forums thread **836760**, verbatim:
> *"The Foundation Models framework **should be available in Europe even if Siri AI is not enabled**.
> Please file a bug report via Feedback Assistant and be sure to include a sysdiagnose to help us
> investigate."*

So the correct framing is: **`SystemLanguageModel.default.availability` currently over-reports
`.appleIntelligenceNotEnabled` on 27 betas, Apple has acknowledged this should not happen, and Apple
has asked for Feedback reports.** It is a bug with an Apple acknowledgement — not a gate you design
around.

> 🔴 **GAP** — **status unresolved as of 2026-07-28.** Thread 835211 has no reply at all; thread
> 836760 has the engineer's statement but no fix, no radar number and no target release. What would
> resolve it: a release-note entry, a beta in which the symptom disappears, or a radar number.

**What this means for your migration, concretely:**

| ❌ Don't | ✅ Do |
|---|---|
| Ship permanent onboarding that instructs users to enable Siri | Handle `.appleIntelligenceNotEnabled` with **generic** copy that doesn't name Siri |
| Write a support article about the Siri toggle | File a Feedback report with a sysdiagnose, as Apple asked, and record the FB number |
| Add a "Siri required" line to your App Store description | Assume the coupling will be removed and that copy will become wrong |
| Treat it as a permanent capability check | Re-test each beta; it may vanish without a release note |

The reason to be firm about this: copy shipped to the App Store outlives betas. If you tell a million
users that your summarizer needs "Hey Siri" turned on, and Apple fixes the defect next month, you own
a wrong support article and a stream of confused reviews forever.

> ⚠️ There is a related, **permanent** constraint that people conflate with this one, so be precise:
> **there is no Required Device Capability for Apple Intelligence.** Apple Frameworks Engineer,
> thread 836810, verbatim: *"**The App Store doesn't support a required device capability for Apple
> Intelligence.** Even on compatible devices, there are a number of reasons why Apple Intelligence
> could be unavailable, such as if the user selected an unsupported Siri language, is located in an
> unsupported region, or opted out of Apple Intelligence."* Apple's stated expectation is that you
> **provide baseline functionality to all users**. That is not a bug, it will not be fixed, and it
> should shape your architecture.

Note also that availability depends on the **Siri language setting, not the system language**
(Settings → Apple Intelligence & Siri → Language), and that `supportsLocale(_:)` returns `true` for a
*close* language — a device set to Catalan reportedly returns `true` because Spanish is supported.
🟡 That last detail comes from a forum reply whose Apple-staff status is ambiguous; treat the
mechanism as attested and the example as illustrative.

### 6.6 BEHAVIOURAL — `.anyOf` still does not constrain

Not new in 27, but it will bite you during a migration because it is exactly the kind of thing a
"the model got worse" investigation blames the model for.

> ✅ **VERIFIED** — Developer Forums thread **812501**. Apple Designer (Apple) **reproduced the bug
> on Apple's end** with:
> ```swift
> @Generable
> struct Arguments {
>     @Guide(description: "The city to get information about.", .anyOf(["London", "New York", "Paris"]))
>     let city: String
> }
> ```
> The model generated **"Beijing"**. A Frameworks Engineer noted it reproduces on **iOS 26.2**.
> Apple's stated intent for `.anyOf` is **both** listing the options in the schema *and* constraining
> generation at prediction time. It does not do the second.

> ⚠️ **SILENT FAILURE.** `.anyOf` produces no error and no warning; it simply doesn't constrain. Your
> tool then receives an argument outside its domain.

Apple's recommended workarounds, in order of what actually holds:

1. **Validate inside the tool** and return a corrective string. ⚠️ The original reporter found the
   model then **loops, re-calling with invalid arguments**. Pair this with a call counter and a hard
   exit (§4.8).
2. **Drop `.anyOf` and put the constraint in ALL-CAPS instructions**, e.g.
   *"You can ONLY call the tool getCityInfo for the these cities: 'London', 'Paris', 'New York'. For
   questions about all other cities you MUST tell the user 'Sorry, I can't look up that city.'"*

And a related gotcha from the same thread, stated by Apple as a general rule even though it wasn't
the cause there:

> ✅ **VERIFIED** — *"Once a `LanguageModelSession` is initialized with a tool, the `parameters`
> property is **computed once and never updated**."* If you build a tool's schema from app state that
> changes, the session keeps the schema it saw at init.

### 6.7 BEHAVIOURAL — errors are thrown from places they weren't

Beyond the taxonomy rename (§7.1), two runtime shapes are new and will surface as "unexplained"
failures in a migrated app.

> ✅ **VERIFIED** — `LanguageModelSession.Error` (new, iOS 27) has exactly two documented cases, and
> both are **session misuse**, not model failure:
> - `.concurrentRequests` — *"Multiple requests were made to the session concurrently."*
> - `.transcriptMutationWhileResponding` — *"The session's transcript was mutated while a request was
>   in progress."*
>
> Note these are **non-payload** cases, unlike the old `GenerationError.concurrentRequests(_:)`.
> (✅ **SDK-verified** — both bare, `Equatable`/`Hashable`;
> `FoundationModels-27.0-macos.swiftinterface:2026-2034`, captured 2026-07-29, recaptured 2026-08-20.)

`.transcriptMutationWhileResponding` is brand-new *because* the transcript became mutable (§4.9). If
you adopt in-place compaction, you now own a concurrency invariant you didn't have before. Apple's
own guardrail for the sibling case is blunt and worth copying:

> ✅ **VERIFIED** — `isResponding` discussion, verbatim: *"**You should not call any of the respond
> methods while this property is `true`.** Disable buttons and other interactions to prevent users
> from submitting a second prompt while the model is responding to their first prompt."*

And a documented footgun with no compile-time signal:

> ✅ **VERIFIED** — from `streamResponse(to:generating:includeSchemaInPrompt:options:)`, verbatim:
> *"**IMPORTANT** — If running in the background, use the non-streaming `respond(to:options:)` method
> to reduce the likelihood of encountering `LanguageModelError.rateLimited(_:)` errors."*

### 6.8 BEHAVIOURAL — concurrency and thermals throttle you, invisibly

> ✅ **VERIFIED** — Apple Frameworks Engineer, thread 833642: the OS limits concurrent requests, and
> **background throttling is possible on iOS**; design for delays and cancellations in background
> tasks.

> ✅ **VERIFIED** — Apple Frameworks Engineer, thread 833666, verbatim: *"The OS manages the requests
> for the on-device LLM automatically, based on the system conditions (like thermals). **There's no
> entitlement or API to influence this.**"*

Nothing here changed in 27 specifically — but a migration that adds PCC, images or reasoning
increases per-request cost, which makes an app that was comfortably inside the envelope on 26 start
meeting the throttle. If your feature runs in the background, measure again after migrating.

Related, and worth knowing before you plan an extension:

> ✅ **VERIFIED** — DTS Engineer (Ziqiao Chen), thread 833575, verbatim: *"The system language model
> (`SystemLanguageModel`) is **not loaded into the app / extension's memory**, and so using it
> **doesn't count on the memory limit of your extension**… **Note that some extensions don't allow
> XPC due to privacy reason, and hence can't use a model via the Foundation Models framework.**"*
> ⚠️ The follow-up asking whether that restriction includes `SystemLanguageModel` is **unanswered**.

### 6.9 BEHAVIOURAL — the Simulator punches out to your Mac

This is the single most important debugging fact in the corpus, and it generates more phantom bug
reports during a migration than anything else, because migration is exactly when your SDK and your
host OS are most likely to disagree.

> ✅ **VERIFIED** — Apple Designer (Apple), Developer Forums thread **831404**, accepted answer,
> verbatim:
> *"Xcode 27.0 contains the latest SDK, but the on-device `SystemLanguageModel` is actually built
> into the OS. **Meaning** that when you run simulator from Xcode, the simulator is actually
> **'punching out' to macOS** to run the model, using the 26.5 model inference code in the OS.
> Whenever we see 'weird' errors like this, it's usually an underlying incompatibility between the
> Xcode SDK and OS for running the model. :( **Suggested Fix** Update a physical device to 27.0."*

Symptoms of the mismatch, all reported and none self-explanatory:

| Symptom | Thread |
|---|---|
| `FoundationModels.LanguageModelError error -1` with nested `ModelManagerServices.ModelManagerError Code=1046` (undocumented) | 831998, 831448 |
| `com.apple.SensitiveContentAnalysisML error 15` (undocumented) on a trivial `#Playground` prompt — *"List all states of USA."* | 836285 |
| PCC failing entirely in the Simulator | 831998 (radar 177684296) |

⚠️ Note the `-1` is **not** simulator-exclusive — a second developer reported it on a physical
iPhone 17 Pro Max with New Siri enabled. So "run it on a device" narrows the search; it does not
guarantee a clean result.

> ✅ **Probe-verified nuance, 2026-07-31** (`probes/` `fm.availability` and the full FM probe set,
> iOS 27.0 Simulator runtime 24A5390f on a macOS 26.5.2 host): "punching out" is not the whole
> picture — **the 27.0 sim runtime resolves model availability and assets independently of the
> host's Apple Intelligence toggle**. With the host toggle OFF (the host itself reports
> `.appleIntelligenceNotEnabled`), the sim reported `available` and ran text inference, guided
> generation, streaming and 8 concurrent sessions. What the sim runtime lacks: tool-calling assets
> (`ModelManagerError 1026` / `UnifiedAssetFramework 5000`) and image attachments
> (`LanguageModelError -1`). So sim errors are not always host-toggle skew — but a sim *result* is
> still not a device result.

**Migration rule, unchanged:** any behavioural result you intend to act on must come from a
**physical device on 27.0 or later**. A Simulator result during a migration tells you about your
Mac and the sim runtime's partial asset set.

### 6.10 BEHAVIOURAL — an OS update invalidates Core AI specialization

Only relevant if you ship your own `.aimodel` assets, but it belongs in a 26 → 27 behaviour list
because the trigger is *the migration itself*.

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, verbatim: specialization
> produces *"executable code tied to that device's hardware **and OS version**."*

Consequences your users experience during the 26 → 27 update, with no code change on your part:

- Every specialization cache entry is invalidated. Your users pay the specialization cost again —
  community-measured at **194 seconds** for a 3 GB model on an iPhone (attributed as
  community-measured).
- A persisted `bookmarkData` for a specialized model **can stop resolving**.
- Ahead-of-time compilation with `xcrun coreai-build compile` reduces this cost but does not remove
  it: artifact generation is inherently per-device.

If you have a "Preparing…" screen, this is the release where it earns its keep. If you don't, this is
the release where users learn your app hangs for three minutes after an OS update.
→ [Part 7 guide 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)
and [guide 17.6](06-toolchain-and-asset-compatibility.md).

---

## 7. RENAMED and SUPERSEDED

The rule for this whole section: **old and new coexist for a cycle.** That is a kindness in one sense
and a trap in another, because "it still compiles" stops being evidence that you've migrated.

### 7.1 RENAMED — `GenerationError` → `LanguageModelError` (and two siblings)

The headline rename, and the one that is worth reading Apple's own words on twice.

> ✅ **VERIFIED** — `/documentation/foundationmodels/languagemodelsession/generationerror`, the
> deprecation notice, verbatim:
> > **Deprecated**
> > Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead.
> > **Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You
> > must update to Xcode 27 to catch the new error types before submitting your app.**

One error type became **three**, split by *what went wrong* rather than *where it surfaced*:

| New type | Domain | Availability |
|---|---|---|
| `LanguageModelError` | the model failed or refused | iOS 27.0+ Beta |
| `SystemLanguageModel.Error` | the on-device Apple model is unavailable | iOS 27.0+ Beta, **no watchOS** |
| `LanguageModelSession.Error` | you misused the session | iOS 27.0+ Beta |
| `PrivateCloudComputeLanguageModel.Error` | PCC-specific (quota, network, service) | iOS 27.0+ Beta |

> ✅ **VERIFIED** — the complete `LanguageModelError` case list, from Apple's documentation with
> Apple's own one-liners; the nine cases are now also ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:1527-1537`, captured 2026-07-29, recaptured 2026-08-20):
>
> | Case | Description |
> |---|---|
> | `.contextSizeExceeded(_:)` | "The session's transcript exceeded the model's context size." |
> | `.rateLimited(_:)` | "The session has been rate limited." |
> | `.refusal(_:)` | "The model refused to answer." |
> | `.timeout(_:)` | "The request timed out before the model could produce a response." |
> | `.guardrailViolation(_:)` | "The model's safety guardrails were triggered by content in a prompt or the response generated by the model." |
> | `.unsupportedCapability(_:)` | "The model being used doesn't support a particular feature." |
> | `.unsupportedTranscriptContent(_:)` | "The prompt contains content that the model cannot process." |
> | `.unsupportedGenerationGuide(_:)` | "An unsupported generation guide was used" |
> | `.unsupportedLanguageOrLocale(_:)` | "The model was prompted to respond in a language that it does not support." |

Apple's own answer to "how do I catch all of this", posted as code by a Frameworks Engineer:

> ✅ **VERIFIED** — Developer Forums thread **831404**, Frameworks Engineer (Apple), verbatim:
> ```swift
> let session = LanguageModelSession()
> let stream = session.streamResponse(to: "Tell me about origami.")
>
> do {
>     for try await partialResponse in stream {
>
>     }
> } catch let error as LanguageModelError {
>
> } catch let error as LanguageModelSession.Error {
>
> } catch let error as LanguageModelSession.GenerationError {
>    // Deprecated in 27.0
> } catch {
>
> }
> ```

Note that Apple's own sample code checks in a **different order** — `SystemLanguageModel.Error`
first, then `LanguageModelError`, then `GeneratedContent.ParsingError` (§6.4). The ordering matters:
`SystemLanguageModel.Error` is a distinct type and availability failures do **not** appear as a
`LanguageModelError` case, so catching `LanguageModelError` first will not shadow it — but putting
the availability check first is what makes the resulting UI copy correct.

> ⚠️ **SILENT FAILURE — this is the defining one for Part 17.** Nothing about a `catch
> GenerationError.guardrailViolation` clause changes when you rebuild with Xcode 27. It still
> compiles. It still looks reachable. It just **stops firing**, because the framework now throws a
> different type — and your `catch { }` fallback silently absorbs everything you thought you were
> handling specially. There is no diagnostic. **Grep your codebase for `GenerationError` before you
> do anything else.**

The old → new mapping in outline (guide [17.3](03-error-taxonomy-migration.md) owns the full table,
including the cases with no counterpart):

| Old (`LanguageModelSession.GenerationError`) | New |
|---|---|
| `.exceededContextWindowSize(_:)` | `LanguageModelError.contextSizeExceeded(_:)` |
| `.unsupportedGuide(_:)` | `LanguageModelError.unsupportedGenerationGuide(_:)` |
| `.guardrailViolation(_:)` | `LanguageModelError.guardrailViolation(_:)` |
| `.rateLimited(_:)` | `LanguageModelError.rateLimited(_:)` |
| `.refusal(_:_:)` — **two** associated values | `LanguageModelError.refusal(_:)` — **one** payload |
| `.unsupportedLanguageOrLocale(_:)` | `LanguageModelError.unsupportedLanguageOrLocale(_:)` |
| `.assetsUnavailable(_:)` | **`SystemLanguageModel.Error.assetsUnavailable(_:)`** — moved types |
| `.concurrentRequests(_:)` | **`LanguageModelSession.Error.concurrentRequests`** — moved types, payload dropped |
| `.decodingFailure(_:)` | **`GeneratedContent.ParsingError`** — ✅ **SDK-named**: the 27.0 interface's deprecation message on the case reads *"Use ``GeneratedContent/ParsingError`` instead."* (`27.0:3555-3558`, captured 2026-07-29, recaptured 2026-08-20). It is a struct, not an enum case, so it needs its **own** catch arm. Whether the framework actually throws it for a guided decode failure is still untested — keep a generic fallback. [17.3 §4.4](03-error-taxonomy-migration.md) has the detail. |

Watch the `.refusal` arity change specifically: a 26-era `catch LanguageModelSession.GenerationError
.refusal(let refusal, _)` does not translate to the 27 case by mechanical edit.

### 7.2 The rename in miniature: TN3193 vs the 2026 samples

If you want one artifact that demonstrates why this migration is confusing, it is this.

> ✅ **VERIFIED** — Apple Technical Note **TN3193**, *"Managing the on-device foundation model's
> context window"*, names the overflow error as:
> **`LanguageModelSession.GenerationError.exceededContextWindowSize(_:)`**

> ✅ **VERIFIED** — Apple's 2026 sample code (Origami and the Spotlight sample, independently) writes:
> **`LanguageModelError.contextSizeExceeded`**

Both are current Apple material. Both describe the same failure. **They are not in conflict — they
are the before and after, published simultaneously.** A Technical Note written for the 26 audience
still names the 26 spelling; compiling 27 sample code uses the 27 spelling.

Practical instruction, for as long as you support both: **catch both.**

```swift prelude:guide-context
import FoundationModels

func summarizeWithOverflowRecovery(_ text: String) async throws -> String {
    let session = LanguageModelSession()
    do {
        return try await session.respond(to: "Summarize: \(text)").content
    } catch let error as LanguageModelError {
        // 27 spelling — ✅ verified in two Apple sample archives.
        if case .contextSizeExceeded = error {
            return try await retryInFreshSession(text)
        }
        throw error
    } catch let error as LanguageModelSession.GenerationError {
        // 26 spelling — ✅ verified in TN3193. Deprecated in 27.0, still catchable.
        if case .exceededContextWindowSize = error {
            return try await retryInFreshSession(text)
        }
        throw error
    }
}
```

Apple's documented recovery for the overflow case is *"create a **new** session, and optionally
preserve context by summarising the old `transcript` or by selecting important entries from it"* —
TN3193 ships an example that keeps the **first and last** transcript entries. On 27 you have a better
option: mutate `transcript.history` in place rather than rebuilding the session (§4.9).

TN3193's six mitigations, worth quoting because they are the checklist for anyone whose context
budget got tighter after migrating:

1. **Split tasks across multiple sessions** — smaller steps, a new session each, combine results.
2. **Request less content** — put the target length in the prompt ("In 3 sentences…") and use
   `Guide(description:)` with `maximumCount(_:)`.
3. **Reduce prompt size** — concise language; 1–3 paragraphs maximum.
4. **Use `Generable` types efficiently** — minimise type complexity, short property names, apply
   `@Guide` sparingly. Every guide costs context.
5. **Optimise tool calling** — brief descriptions, **limit to 3–5 tools**, and consider running tools
   *before* calling the model.
6. **Implement RAG** — fetch relevant snippets dynamically instead of passing a whole knowledge base.

> 🔴 **GAP** — TN3193 says **nothing** about KV-cache behaviour or transcript-trimming APIs. Any
> claim you read about cache invalidation semantics rests on WWDC26 session 242 plus the
> `foundation-models-utilities` source, not on this note. Don't upgrade those markers on TN3193's
> strength.

### 7.3 RENAMED — sampling mode cases

Two renames landed *between Xcode 27 betas*, which is worth knowing because it means beta-era sample
code you find online may not compile.

> ✅ **VERIFIED** — commit `376ca60` on `apple/foundation-models-utilities` (tag `1.0.0-beta3`,
> 2026-07-10), whose message doubles as a beta1 → beta3 framework changelog, verbatim first bullet:
> *"Renamed SamplingMode enum cases — `.top` → `.randomTopK` and `.nucleus` →
> `.randomProbabilityThreshold`."*

> ✅ **VERIFIED** — corroborated independently by `ml-explore/mlx-swift-lm` commit `2a76e56`:
> *"FoundationModels renamed `GenerationOptions.SamplingMode.Kind`'s `.top`/`.nucleus` cases to
> `.randomTopK`/`.randomProbabilityThreshold`, which broke compilation against the newer SDK."*
> And now ✅ **SDK-verified** — the 27.0 interface declares
> `case randomTopK(_: Int, seed: UInt64?)` and `case randomProbabilityThreshold(_: Double,
> seed: UInt64?)`, with no `.top` / `.nucleus` anywhere in the file (`27.0:3283-3284`).

And a separate, older rename on the surrounding API:

> ✅ **VERIFIED** — `GenerationOptions` has `var samplingMode: GenerationOptions.SamplingMode?`, with
> `var sampling` marked **(Deprecated)**, and `init(sampling:temperature:maximumResponseTokens:)`
> likewise deprecated in favour of `init(samplingMode:temperature:maximumResponseTokens:)` and the
> four-argument 27 form. ✅ **SDK-verified**, with one detail only the interface shows: `sampling` is
> `@available(*, deprecated, renamed: "samplingMode")` (`27.0:3202-3205`) and the current
> `samplingMode` is a **back-deployed computed alias that reads and writes `sampling`**
> (`@backDeployed(before: iOS 27.0, …)`, `27.0:3229-3241`) — so the rename is source-level only and
> both spellings hit the same storage.

⚠️ Note the asymmetry that survives: the **factory** is `random(top:seed:)` while the **`Kind` case**
is `randomTopK`. Both are correct; they are different levels of the API.

Also worth recording before you build determinism into a test suite:

> ✅ **VERIFIED** — stated on **both** `random` pages, verbatim: *"Setting a random seed is **not
> guaranteed** to result in fully deterministic output. It is **best effort**."*
> Use `.greedy` when you need reproducibility, as Apple's own code-along does.

### 7.4 RENAMED — `.model(_:)` moved from the utilities package into the framework

A small item with a real consequence: code written against `utilities` beta 1 may now be ambiguous.

> ✅ **VERIFIED** — commit `376ca60`, verbatim: *"Removed `.model(any LanguageModel)` modifier since
> it's now included in the Foundation Models framework."*

The deleted implementation is instructive if you are writing your own type-erasure over
`LanguageModel`: `git show a047a50:…/DynamicProfile+LanguageModel.swift` contains a complete
hand-rolled 92-line `AnyLanguageModel`, including an `unsafeBitCast` of a metatype to
`UnsafeRawPointer` purely to obtain `Hashable` — which tells you how load-bearing
`Executor.Configuration: Hashable` is to the executor cache.

From the same commit, two more that change code you may have written against beta 1:

- **`SkillActivations` no longer conforms to `RandomAccessCollection`** — replaced by a public
  `activeSkillNames` property and an `isActive(_:)` method.
- **`ChatCompletionsLanguageModel.init` gained `urlSessionConfiguration`**, defaulting to an ephemeral
  configuration. ⚠️ It is **excluded from the `Configuration`'s `==`/`hash`**, so two models differing
  only in transport settings are cache-equal and the framework may hand you an executor built with
  the wrong session. Latent, but real; ✅ verified in source.

### 7.5 SUPERSEDED — session initializer labels

> ✅ **VERIFIED** — Apple's 2026 Origami sample uses **`LanguageModelSession(profile:history:)`** where
> `history: Transcript`. Apple's 26-era coffee-game sample uses **`LanguageModelSession(transcript:)`**.
> Both labels appear in shipping Apple code.

> ✅ **RESOLVED 2026-07-29** (was a 🔴 GAP) — `transcript:` is **not** deprecated. The 27.0 beta
> interface declares `init(model: SystemLanguageModel = .default, tools: [any Tool] = [],
> transcript: Transcript)` with no deprecation attribute (`27.0:41`), and even adds a **new**
> generic-model sibling, `init(model: some LanguageModel, tools: [any Tool] = [], transcript:
> Transcript)` (`27.0:1948-1951`). The 27-era additions are `init(profile:history:)` (`27.0:916`)
> and `init(model:dynamicInstructions:history:)` (`27.0:1126`), where `history:` is a
> `some Collection<Transcript.Entry> = []`, not a `Transcript`-only label.
> The advice stands on style grounds: use `history:` in new 27-only code, leave `transcript:` alone
> in code that must also build against 26 — but nothing is going away this cycle.

Also new and easy to miss when constructing a transcript by hand:

> ✅ **VERIFIED** — from the sample: `Transcript(entries: [Transcript.Entry])`,
> `.response(Transcript.Response(assetIDs:segments:))`, `.text(Transcript.TextSegment(content:))` —
> and **`assetIDs` is a required `[String]`**; Apple's own sample passes `[""]`. `Transcript` is
> `Encodable`, so `JSONEncoder().encode(session.transcript)` works and is the cheapest possible
> migration-era diagnostic.

### 7.6 RESOLVED — `ImageReference.resolve(in:)` vs `resolved(in:)`

Tiny — and the deprecation warning is SDK-dependent: only a build that declares it will warn.

> ✅ **VERIFIED** — the documentation harvest (2026-07-27) presents `func resolved(in:) ->
> Transcript.ImageAttachment?` as current and `func resolve(in:)` as **(Deprecated)**.

> ✅ **RESOLVED 2026-09-07 — current docs now match beta 5.** The beta-4 interface
> (`27A5228h`) contains only un-deprecated `resolve(in: Transcript)`
> (`27.0:2959-2963` in that superseded capture). The beta-5 interface (`27A5237l`) instead contains
> only un-deprecated `resolved(in: some Sequence<Transcript.Entry>)` (`27.0:3024-3027`). Apple's
> current [`ImageReference`](https://developer.apple.com/documentation/foundationmodels/imagereference)
> page now lists only the sequence spelling and uses `resolved(in: history)` in its overview,
> matching beta 5. A documentation changes view still exposes the deprecated whole-`Transcript`
> overload as historical API, but it is no longer part of the default current surface. **Do not
> mechanically rename across toolchains**: beta 4 still requires the older spelling and argument
> type.

### 7.7 SUPERSEDED — hand-rolled context management

Not an API rename, but a "you can delete this now" item, and one of the few places in this migration
where you get to remove code.

If your 26.x app has a wrapper that checks `tokenCount(for:)`, compacts at a threshold, retries once
on `exceededContextWindowSize` and rebuilds a session from the compacted `Transcript` — that is a
well-known community pattern (one such wrapper was published as `FoundationContext`), and it is
exactly what Apple replaced.

> ✅ **VERIFIED** — Apple Frameworks Engineer, thread 835927, on precisely that wrapper: recreating
> the session is correct **for iOS 26**; on iOS 27 use the mutable `transcript` / `history` accessor,
> or the open-sourced modifiers in `foundation-models-utilities`.

⚠️ One caveat before you swap wholesale: **`summarizeHistory` destroys tool-call metadata.**

> ✅ **VERIFIED** — Apple Designer (Apple), thread 833706, verbatim: *"'Summarize History' modifier
> currently doesn't support preserving metadata like tool call IDs."* And from a Frameworks Engineer
> in the same thread: *"it will condense all entries into a `.prompt` entry. If you're looking to
> preserve `.toolCalls` entries during summarization, you should be able to implement your own
> modifier using **`DynamicProfileModifier`** and either **`historyTransform`** or lifecycle modifiers
> (like **`onPrompt`**)."*

---

## 8. WITHDRAWN

One thing was withdrawn at the 26→27 boundary — the headline extensibility story of the 2025
release — and one 27-only surface has since vanished mid-beta (§8.3).

### 8.1 WITHDRAWN — custom LoRA adapters

> ✅ **VERIFIED** — **Frameworks Engineer (Apple)**, Developer Forums thread **829108**, verbatim:
> *"@alex_und3r, as we announced at WWDC26, **custom adapters are unfortunately no longer supported as
> of OS 27**. Instead, you can use the base machine-learning models that are available on people's
> devices or provide your own custom models using **Core ML or Core AI**. **Background Assets** remains
> a great way to deliver custom models to your users."*

> ✅ **VERIFIED** — **Apple Designer (Apple)**, Developer Forums thread **831314**, verbatim:
> *"Sorry, we're no longer supporting adapters as of OS 27. I'll update the page."*

Two independent Apple statements, in two different threads, from two different badges. This is not a
rumour — and as of this revision it is also **written into the SDK**. ✅ **SDK-verified**
(`FoundationModels-27.0-macos.swiftinterface`, captured 2026-07-29, recaptured 2026-08-20): the 27.0 interface marks
`SystemLanguageModel.Adapter` and its working surface (`init(fileURL:)`, `init(name:)`,
`compile()`, `compatibleAdapterIdentifiers(name:)`) as
**`@available(iOS, deprecated: 26.4, obsoleted: 27.0)`** (same for macOS/visionOS; `27.0:509-551`),
and `SystemLanguageModel.init(adapter:guardrails:)` as **`obsoleted: 27.0`** (`27.0:395-400`).
`obsoleted:` is stronger than deprecation: with a 27.0 deployment target the adapter code **fails to
compile**. Note the back-dating — Apple's own annotation says adapters were *deprecated at 26.4*,
the release that swapped the base model. For contrast, the captured **26.5** interface carries no
deprecation on any of it (`26.5:578-671`), so the marks arrived with the 27 SDK. The `AssetError`
family is the exception: deprecated 26.4 but **not** obsoleted (`27.0:553-605`), so a dual-target
app can still name the old error cases. [17.2](02-adapter-sunset.md) folds this into the full
story.

Corroborating detail from the OP of 831314: *"The toolkit version page currently lists **26.0.0** as
the latest, noted as the last release for the OS 26 line."*

**What goes away with it:**

| Thing | Status |
|---|---|
| `SystemLanguageModel.Adapter` | **`deprecated: 26.4, obsoleted: 27.0`** in the 27 SDK — compile error at a 27.0 deployment target |
| `.fmadapter` bundle format | historical |
| `xcrun ba-package foundation-models package …` | the subcommand still ships in the Xcode 27.0 beta (checked 2026-07-29) — but the runtime API that would consume its output is obsoleted; see [17.2 §2](02-adapter-sunset.md) |
| Adapter Training Toolkit | stops at **26.0.0** |
| `com.apple.developer.foundation-model-adapter` entitlement | historical |

> ⚠️ **This is not a deprecation with a replacement.** It is a removal with a *differently shaped*
> replacement in a *different framework*. "Train a small delta on top of Apple's model and ship it"
> has no successor. "Bring a whole model of your own and drive it through the `LanguageModel`
> protocol" is the successor to the *goal*, not to the *mechanism* — and it costs you app size,
> download management, and (per §4.3) possibly guided generation.

> 🔴 **GAP** — Apple names the migration path (Core ML / Core AI plus Background Assets) but has
> **documented it end to end nowhere.** There is no LoRA → Core AI recipe, and no Core AI equivalent
> of the Adapter Training Toolkit that we can find. What would resolve it: an Apple documentation
> article or sample. **Safe default:** before assuming a fine-tune is required at all, re-test the
> task as prompting + guided generation against the **rebuilt 27 model** — session 241's whole pitch
> is that it is *"better at logic and tool calling"*, and several adapter use cases from 2025 were
> compensating for the 2025 model.

> ⚠️ **Never write about an on-device LoRA *training* API.** There has never been one. Adapters were
> trained off-device with the Python toolkit and *delivered* to the device. Claims of an on-device
> training API are fabricated and are in circulation.

Guide [17.2](02-adapter-sunset.md) owns the full story, including the three realistic forward paths
and the `compatibleAdapterNotFound` failure for readers still supporting a 26.x build.

### 8.2 Not withdrawn, but never shipped: a speech-generation API

Worth a line here because developers keep migrating *toward* it.

> ✅ **VERIFIED** — Apple Designer (Apple), Developer Forums thread **834149**, verbatim: *"The short
> answer is **no**. **No new API has been released specific to that model.** Though of course you
> still have the older existing speech synthesis APIs in AV Foundation."*

The WWDC26 keynote described a second on-device model that *"lets supported products understand and
generate speech"*. That capability is **not exposed to third-party developers** as of July 2026. If a
migration plan in your organisation assumes a new TTS API, it is built on a keynote sentence, not an
API. → [Part 16](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-16-adjacent-capabilities/README.md).

### 8.3 WITHDRAWN mid-beta — `Transcript.CustomSegment` and `.updateCustomSegment(_:)` (beta 5)

The 27 cycle's own extension point for provider-defined transcript content did not survive the beta
cycle. The 2026-07-29 capture of the 27.0 interface declared the `Transcript.CustomSegment`
protocol, a `Transcript.Segment.custom(any CustomSegment)` case, and a
`LanguageModelExecutorGenerationChannel.Response.Action.updateCustomSegment(_:)` channel action.

> ✅ **SDK-verified (beta 5 recapture; noted 2026-08-23)** — the recaptured
> `FoundationModels-27.0-macos.swiftinterface` contains **zero occurrences of `CustomSegment`**.
> The removal happened between the 2026-07-29 capture and beta 5: `Transcript.Segment` now has
> exactly three cases — `.text`, `.structure`, `.attachment` (`27.0:2288-2297`) — and the
> response-action surface is `appendText` / `replaceTextSegment` / `addAttachmentSegment` /
> `removeAttachmentSegment` / `updateMetadata` / `updateUsage` (`27.0:1857-1864`). This is a
> statement about the beta 5 interface, not a permanent claim — the surface may return in a later
> beta, and WWDC session 339, the provider skill, and the docs index still describe it. Provider
> guidance and the safe default live in
> [Part 4 §13.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md).

For a migrating team the practical impact is narrow — no 26.x code can reference the symbol (it was
27-only from the start) — but any beta-4-era provider or transcript code built against `.custom(_:)`
or `.updateCustomSegment(_:)` no longer compiles against the beta 5 SDK.

---

## 9. The Python SDK generation lag

WWDC26 presented the Foundation Models SDK for Python as part of this year's story. The repository
tells a different version of events, and the difference matters if you were planning to drive a
migration-era evaluation harness from Python.

**State it plainly: `apple/python-apple-fm-sdk` is a 26-generation artifact.**

> ✅ **VERIFIED** — `README.md:25-30` and `docs/source/index.rst:23-30` of the repository, the stated
> requirements:
> - **macOS 26.0+**
> - **Xcode 26.0+**, *"and agree to the Xcode and Apple SDKs agreement in the Xcode app"*
> - **Python 3.10+**
> - **Apple Intelligence turned on for a compatible Mac**

> ✅ **VERIFIED** — `foundation-models-c/Package.swift:13`:
> ```swift
> platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)],
> ```

> ✅ **VERIFIED** — Apple's own release-notes page dates it to the **March 2026** wave, not June:
> *"Use the **Foundation Models SDK for Python** … to access the on-device foundation model at the
> core of Apple Intelligence."*

So the SDK belongs to the 26 generation, and its feature set follows. **It does not expose:**

| 27 feature | In the Python SDK? |
|---|---|
| `PrivateCloudComputeLanguageModel` / PCC | **No.** Session 241 describes the SDK as giving *"direct access to the very same **on-device** model"*; PCC is never mentioned from Python anywhere. |
| Dynamic Profiles | **No.** No `DynamicProfile`, `Profile`, `DynamicInstructions` or modifiers exist in the Python or C surface. |
| The `LanguageModel` / `LanguageModelExecutor` protocol | **No.** There is no model-abstraction layer; `fm.SystemLanguageModel()` is the only model. |
| Structured streaming | **No.** `stream_response` yields `str` only; the Swift shim hard-codes `ResponseStream<String>`. `PartiallyGenerated` classes are generated for every `@generable` type and **never used**. |
| `Response` wrapper / `usage` | **No.** You get the bare `str` / typed object and must re-read `session.transcript` for entries. |
| `prewarm`, adapters, `Instructions` builders, `Tool.Output` richness, `DynamicGenerationSchema(anyOf:)` | **No.** |

Image input is the one 27-era feature it *can* reach, and only conditionally:

> ✅ **VERIFIED** — `build_backend.py:148-152`, the gate:
> ```python
> # `Attachment` (image support) only exists in the macOS 27+ SDK
> extra_swift_args = []
> sdk_major = _macos_sdk_major_version()
> if sdk_major is not None and sdk_major >= 27:
>     extra_swift_args += ["-Xswiftc", "-DFM_HAS_MACOS_27_SDK"]
> ```
> and in the Swift shim: `#if FM_HAS_MACOS_27_SDK` + `if #available(iOS 27.0, macOS 27.0, visionOS 27.0,
> watchOS 27.0, *)`.

> ⚠️ **SILENT-ish FAILURE — a wheel built on Xcode 26 permanently lacks image support.** The
> capability is baked in at *build* time, not detected at run time. It does at least raise rather than
> no-op — `ImagePromptError: … the Xcode version used to build this package doesn't include macOS 27
> SDKs` — but the failure surfaces on your first image call, potentially long after the wheel was
> built by CI on the wrong runner. **Image prompts need the macOS 27 SDK at build time AND macOS 27
> at run time.**

Token counting has its own floor, enforced in the shim:

> ✅ **VERIFIED** — `guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *)`, otherwise an
> `NSError(domain: "TokenCount", code: -1)` with the description
> *"Token counting requires macOS 26.4, iOS 26.4, or visionOS 26.4 or later."*
> `FMSystemLanguageModelGetContextSize` (i.e. `model.contextSize`) is **not** gated — consistent with
> the back-deployment attribute in §1.1.

### 9.1 What the SDK *is* good for during a migration

Apple's own positioning is narrow and accurate:

> ✅ **VERIFIED** — `docs/source/index.rst:13-16`, verbatim: *"You can use this Python SDK to
> **evaluate** your Swift app's Foundation Models features … so you can be confident that your
> evaluations reflect real on-device performance and behavior."*

That is exactly the migration use case: batch-run your 26-era prompt corpus against the on-device
model, dump results to a DataFrame, and diff. Apple's session 334 case study does precisely this and
produces the prompt-length finding quoted in §6.1.

```python
# ✅ Shape verified against README.md:55-72 of apple/python-apple-fm-sdk.
import asyncio
import apple_fm_sdk as fm

async def main():
    model = fm.SystemLanguageModel()
    is_available, reason = model.is_available()   # note: a 2-TUPLE, not Swift's enum
    if not is_available:
        print(f"Foundation Models not available: {reason}")
        return

    session = fm.LanguageModelSession()
    response = await session.respond("Hello, how are you?")
    print(f"Model response: {response}")

asyncio.run(main())

# Token budgeting — mirrors Swift's tokenCount(for:) overloads.
# ✅ context_size / token_count added in commit db7afde; token_count requires macOS 26.4+.
async def budget(session_tools, MyType):
    model = fm.SystemLanguageModel()
    budget = model.context_size
    used  = await model.token_count("Tell me about the history of Swift.")
    used += await model.token_count(instructions="You are a helpful assistant.")
    used += await model.token_count(session_tools)
    used += await model.token_count(MyType.generation_schema())
    print(f"Using {used} of {budget} tokens")
```

### 9.2 Four Python-SDK defects that will waste your afternoon

All ✅ verified by reading the repository at HEAD `e868e60`.

1. **`respond(..., generating=X, options=...)` silently drops `options`** (`session.py:473`). Your
   `temperature` and `maximumResponseTokens` do nothing on the guided-generation path.
2. **Random sampling params and seeds are silently ignored.** `GenerationOptions.to_dict()`
   stringifies `top_k` / `top_p` / `seed`, while the Swift side casts them as `Int` / `Double` /
   `UInt64`. Only `greedy`, `temperature` and `maximum_response_tokens` actually take effect.
   ⚠️ If you are using a seed to make an evaluation reproducible, **you are not**.
3. **Optionality detection is a string test.** `Property.convert_to_c` decides optionality with
   `"Optional" in str(type)`. So `x: str | None` (PEP 604) is **never** optional on Python ≤3.13 —
   and on **Python 3.14** even `typing.Optional[X]` stops being detected, because `str(Optional[int])`
   became `'int | None'`. (Measured across 3.11–3.14.) Use `typing.Optional[X]` and pin ≤3.13.
4. **`apple_fm_sdk.__version__` lies** — it reports `"0.1.0"` while the package version is `0.2.1`.
   Use `importlib.metadata.version("apple-fm-sdk")`.

Also note: **tool exceptions never surface as Python exceptions.** They are converted to the string
`"Tool error: <msg>"` and fed back to the model; `fm.ToolCallError` is never raised by the SDK. ⚠️ A
tool that fails in your evaluation harness therefore *looks like a model quality problem*.

> 🔴 **GAP** — the README's feature list does **not** mention tool calling, while session 334 says
> *"you can use **tool calling** to enable the model to interact with code."* The `tool.py` module
> exists and tests exercise it, so the capability is real; the README is simply behind. What would
> resolve it: a README update or a version note. **Safe default:** assume tool calling works but
> verify against `tests/test_tool.py` for the exact shape rather than the README.

**The bottom line for a migration:** use the Python SDK to *measure* the on-device model across the
26 → 27 boundary. Do not plan to exercise PCC, profiles, or the model-abstraction layer from Python.
For profiles and the model-abstraction layer, use Swift interop. Beta-era `fm` reached PCC via its
model option, but stable macOS 27 advertises only `system`; no current non-Swift PCC route is
established. See [5.2 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md#3--the-fm-help-surface-captured-on-macos-27).

---

## 10. Toolchain breakages

These are the failures that are not your code's fault. Each has been reported by a developer, and
several have an Apple acknowledgement. Check this table before you spend a day bisecting.

| # | Symptom | Cause | Status | Source |
|---|---|---|---|---|
| 1 | `FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15 Unable to resolve module dependency: 'CoreImage'` on **watchOS 27 Beta 2** | The module interface imports CoreImage — almost certainly fallout from the new image-attachment API — on a platform that lacks it | ✅ **"This is a known bug"** — Apple Frameworks Engineer, accepted answer | thread 835987 |
| 2 | `SkillActivation` APIs from `foundation-models-utilities` **fail to build on Xcode 26** | The package declares `.macOS("27.0") / .iOS("27.0") / .visionOS("27.0") / .watchOS("27.0")` — it is a 27-only package | Reported; Apple asked for the specific errors; **never resolved in thread** | thread 835165 |
| 3 | `import MLXFoundationModels` **not found**; "there are even no BETA branches on the MLX framework" | It is a library target inside `ml-explore/mlx-swift-lm`, not a separate repo | ✅ Answered by Apple: *"This is being introduced to `mlx-swift-lm` in **PR#334**"* | thread 836264 |
| 4 | `MLXFoundationModels` **compiles to an empty library** and every symbol vanishes | Gated on `#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)` — the `_version: 2` check is true **only on the 27.0 SDK** | Working as designed; you need Xcode 27 | `mlx-swift-lm` `Package.swift` + commit `3cbf928` |
| 5 | `.package(url: "…/foundation-models-utilities", from: "1.0.0")` **resolves to nothing** | Only prerelease tags exist (`1.0.0-beta1`, `1.0.0-beta3`); SwiftPM's `from:` excludes prereleases | Real; pin `exact: "1.0.0-beta3"` | ✅ `git ls-remote --tags` |
| 6 | PCC calls fail in the **Simulator** | Known issue **177684296**, in the iOS 27 release notes | ✅ Apple-documented. Workaround: *"Use a physical device running OS 27.0."* | thread 831998 |
| 7 | A build that links `updateUsage(input:output:metadata:)` **SIGSEGVs at load** | The 27-beta `.swiftinterface` declares `LanguageModelExecutorGenerationChannel.Response.Action.updateUsage(input:output:metadata: = [:])` but the **shipping dylib exports only `updateUsage(input:output:)`**; the compiled reference alone crashes under chained-fixups linking | Community-found; `mlx-swift-lm` removed the call entirely (`1c86cc1`) | ✅ commit message |
| 8 | Wheels of `apple-fm-sdk` built on an Xcode-26 runner raise `ImagePromptError` on every image call | `-DFM_HAS_MACOS_27_SDK` is decided at build time from `xcrun --sdk macosx --show-sdk-version` | Working as designed; pin your CI runner | ✅ `build_backend.py:43-54, 148-152` |

### 10.1 The pattern behind the table

Items 2, 4 and 8 are the same failure wearing three costumes: **a capability gated on the SDK version
rather than the runtime OS version.** You cannot paper over any of them with `if #available` — the
symbols do not exist to be conditionally called.

The industrial-strength version of the fix, and the one worth stealing, is `mlx-swift-lm`'s CI shell:

```bash
# ✅ VERIFIED — .github/workflows/integration_tests.yml:21-42, ml-explore/mlx-swift-lm, verbatim.
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

Note what it does: it **selects a toolchain**, and if it can't find one it **says so in the log** and
runs a reduced suite. It does not silently pass. That is the property you want — the failure mode of
a dual-SDK setup is a green build that tested nothing.

Guide [17.4](04-dual-sdk-builds.md) owns the source-level technique.

### 10.2 Freshness caution

Every row in the table above was captured against betas in June–July 2026. Betas move.

> 🔴 **GAP** — the **current** status of rows 1, 2, 6 and 7 is unknown as of 2026-07-28. What would
> resolve each: re-running the exact reproduction on the current beta. **Safe default:** re-test
> before you build a workaround into your codebase, and prefer workarounds you can delete (a CI
> toolchain selector) over ones you cannot (a fork).

---

## 11. Every silent failure in this migration, collected

The series convention is at least one ⚠️ **SILENT FAILURE** callout per guide. For Part 17 the
callouts *are* the guide, so here they are in one place, ranked by how much money they can cost you.

| # | The failure | Why it's silent | Detect it by | §  |
|---|---|---|---|---|
| 1 | **`catch GenerationError` stops firing when you rebuild with Xcode 27** | The clause still compiles and still looks reachable. The framework throws a different type; your generic `catch` absorbs it. | `grep -rn GenerationError` across the project. Then force each error path in a test. | [§7.1](#71-renamed--generationerror--languagemodelerror-and-two-siblings) |
| 2 | **A string-generating feature that gets refused returns a successful response containing an apology** | Refusal of a string response is *text*, not an error. Apple says you may not be able to tell them apart programmatically. | Classify responses with a second session, or assert on a prefix, in your evaluation suite. | [§6.3](#63-behavioural--refusal-traffic-moved-between-two-mechanisms) |
| 3 | **`.permissiveContentTransformations` does nothing for `@Generable`** | It compiles, it's the documented knob, and it looks like it's working until you feed it a sensitive input. | Test the knob against your actual guided-generation path, not against a string prompt. | [§6.2](#62-behavioural--guardrails-changed-twice) |
| 4 | **Prompts tuned on 26.x silently degrade on the rebuilt 27 model** | No error, no warning, no API to detect a model change. Output is merely *different*. | An Evaluations run with a pre-migration baseline. | [§6.1](#61-behavioural--the-on-device-model-was-rebuilt) |
| 5 | **`toolCallingMode: .required` with no exit condition loops forever** | Apple documents it, but the symptom is "the request never returns", which reads as a hang, not a bug. | A `@SessionProperty` call counter that flips the mode. | [§4.8](#48-additive--toolcallingmode-and-its-exit-condition-trap) |
| 6 | **`Attachment(image)` without `.label(_:)` no-ops for image tool calls** | The prompt still sends, the model still answers — it just improvises without the image. | Label every attachment. Assert the tool actually received an image. | [§4.1](#41-additive--image-input-on-the-on-device-model) |
| 7 | **A stream can yield zero partials when the model emits only a tool call** | "Spinner until first token" UI waits forever; nothing throws. | Track a `didReceivePartial` flag and land in a terminal state regardless. | [§6.4](#64-behavioural--apples-samples-dropped-proactive-availability-gating) |
| 8 | **`@Guide(.anyOf(…))` does not constrain generation** | No error. The tool just receives an out-of-domain argument. | Validate inside `call(arguments:)`; add the constraint to instructions in ALL-CAPS. | [§6.6](#66-behavioural--anyof-still-does-not-constrain) |
| 9 | **Reactive-only availability gating lets a user pay before discovering the feature can't run** | Nothing fails — until the tap. Apple's own samples model this pattern. | Proactive `availability` switch **and** reactive catching. | [§6.4](#64-behavioural--apples-samples-dropped-proactive-availability-gating) |
| 10 | **A Simulator result during migration measures your Mac, not the target OS** | Everything runs. Errors are numeric and undocumented (`-1`, `1046`, `error 15`). | Physical device on 27.0+. Treat Simulator results as non-evidence. | [§6.9](#69-behavioural--the-simulator-punches-out-to-your-mac) |
| 11 | **`MLXFoundationModels` compiles to an empty library on the 26 SDK** | It's a green build. Your integration tests compile out and pass by not existing. | Fail the build (or log loudly) when the 27 SDK isn't found — see the CI snippet in §10.1. | [§10](#10-toolchain-breakages) |
| 12 | **Python: `respond(generating=…, options=…)` drops `options`; seeds and top-k are stringified away** | Your evaluation harness reports numbers from settings that were never applied. | Run the same seeded prompt twice and compare. | [§9.2](#92-four-python-sdk-defects-that-will-waste-your-afternoon) |
| 13 | **`.preserveTranscript` can retain a half-generated entry** | It's the option you'd pick to "not lose context". The partial entry then feeds the next turn. | Validate the last entry after any error when preserving. | [§4.10](#410-additive--transcripterrorhandlingpolicy) |
| 14 | **Core AI specialization caches are invalidated by the OS update itself** | Nothing errors; the app just stalls on first load after the user updates. | A "Preparing…" gate driven by `AIModelCache.default.model(for:options:)` returning `nil`. | [§6.10](#610-behavioural--an-os-update-invalidates-core-ai-specialization) |
| 15 | **`ChatCompletionsLanguageModel` mangles URLs for any provider not on `/v1`** | It's a 404 from the provider, which reads as a config error on your side. | Log the composed request URL once at startup. | [§5.3](#53-additive--chatcompletionslanguagemodel-turns-your-existing-stack-into-a-backend) |

---

## 12. The migration checklist

Work down. Do not reorder — steps 1–4 are the ones that catch problems while they're still cheap, and
every one of them is free.

### Phase 0 — Before you change anything

- [ ] **Capture a baseline.** On a device still running 26.x, record real model output for your top
      20 prompts, verbatim, with the OS build number. Once your fleet updates you cannot recover this.
      This is the single highest-value thing in the whole checklist and it takes an afternoon.
- [ ] **Write down which OS floor each feature in your app requires.** Use the table in §1. Most teams
      discover at this step that they have been treating 26.4 features as 26.0 features.
- [ ] **Record your current Xcode version, macOS version, and deployment target** in the migration
      ticket. You will need all three to interpret every failure below.

### Phase 1 — The grep pass (30 minutes, no build required)

- [ ] `grep -rn "GenerationError"` — every hit is potentially dead code after you rebuild. → §7.1
- [ ] `grep -rn "guardrailViolation"` — check whether the surrounding logic assumes it is the *only*
      refusal mechanism. → §6.3
- [ ] `grep -rn "\.anyOf"` — each one needs a validation path in the tool. → §6.6
- [ ] `grep -rn "fmadapter\|SystemLanguageModel.Adapter\|ba-package"` — if anything hits, stop and
      read [guide 17.2](02-adapter-sunset.md) before continuing.
- [ ] `grep -rn "4096\|8192"` — hardcoded context sizes. Replace with `contextSize`. → §1.1
- [ ] `grep -rn "sampling:"` — the deprecated `GenerationOptions` label. → §7.3
- [ ] `grep -rn "\.top\b\|\.nucleus"` in sampling contexts — renamed between betas. → §7.3
- [ ] Search your UI strings for **"Siri"**. If your onboarding tells users to enable Siri to use an
      AI feature, delete it. → §6.5

### Phase 2 — Rebuild with Xcode 27

- [ ] **Rebuild and read every deprecation warning.** This is the moment the error taxonomy actually
      changes. → §7.1
- [ ] Add `catch let error as LanguageModelError` / `catch let error as SystemLanguageModel.Error` /
      `catch let error as LanguageModelSession.Error` clauses. Keep the `GenerationError` clause for
      as long as you ship a 26 build. → §7.2
- [ ] Add a `default: break` to every `switch` over `LanguageModelError` — it is **non-frozen**. → §6.4
- [ ] Catch `GeneratedContent.ParsingError` separately. Apple's samples do. → §6.4
- [ ] If you use tools that throw: decide `.preserveTranscript` vs `.revertTranscript` **explicitly**
      rather than inheriting a default we cannot verify. → §4.10
- [ ] If you have a dual-SDK requirement, set up the toolchain selector **now**, and make it fail
      loudly. → §10.1

### Phase 3 — Behaviour, on a physical device

- [ ] **Get a physical device on 27.0+.** Nothing in this phase counts otherwise. → §6.9
- [ ] Re-run your baseline prompts. Diff against Phase 0. → §6.1
- [ ] Re-test every prompt that touches a sensitive domain — health, finance, legal, safety, bodies,
      substances, personal data. Expect new refusals; expect them as a *different error type* than
      before. → §6.3
- [ ] Verify that a refusal on a **string**-generating path is detectable in your code at all. If it
      isn't, add a classifier pass or convert the path to guided generation. → §6.3
- [ ] Audit every streaming UI for the zero-partials case. → §6.4
- [ ] Check availability handling **both ways**: proactive gate + reactive catch. → §6.4
- [ ] Measure again under load / in the background. The concurrency and thermal envelope did not
      change, but your per-request cost may have. → §6.8
- [ ] If you ship `.aimodel` assets: measure first-load time **after** an OS update, not before.
      → §6.10

### Phase 4 — Instrumentation (do this before adopting anything new)

- [ ] Wire up `Response.usage` / `session.usage`. Record input tokens, cached input tokens, output
      tokens, reasoning tokens. → §4.7
- [ ] Replace hardcoded token budgets with `contextSize` + `tokenCount(for:)`. → §1.1
- [ ] Stand up an **Evaluations** suite with your Phase 0 baseline as the dataset. This is the only
      durable defence against §3.1 (no model pinning). → §5.1
- [ ] Profile with the updated Foundation Models instrument. Apple's 2026 release notes call it out
      specifically as giving *"insight into latency, prompts sent to the model, model output, tools
      and token usage."*

### Phase 5 — Only now, adopt

In roughly increasing order of risk:

- [ ] `usage` and `contextSize` — already done in Phase 4, zero risk.
- [ ] `toolCallingMode` — cheap, but read §4.8's exit-condition warning first.
- [ ] Mutable `transcript` / `history` — and delete your hand-rolled compaction. → §7.7
- [ ] Image input — remember `.label(_:)`, and don't use it for coordinates. → §4.1
- [ ] The Vision tools (`OCRTool`, `BarcodeReaderTool`) — remember `import Vision`, and that
      `OCRTool` has no watchOS. → §4.6
- [ ] Dynamic Profiles — the largest structural change, and the one most likely to be worth it if you
      currently juggle multiple sessions. → §4.4
- [ ] `SpotlightSearchTool` — read §4.6's two open defects first.
- [ ] The `utilities` package (Skills, history modifiers) — pin an exact prerelease tag. → §4.5
- [ ] PCC — **lead with eligibility**, not with API. → §4.2
- [ ] A custom `LanguageModel` conformance — and check `@Generable` survives your backend choice
      first. → §4.3

### Phase 6 — Ship, then keep watching

- [ ] Re-run the Evaluations suite on **every** OS point release, not just major versions. The 26.4
      model swap is the precedent: it was a point release and it changed the model. → §3
- [ ] Keep the Phase 0 baseline. It's the only record of what your feature used to do.
- [ ] File Feedback reports for anything in §10 you still hit, with a sysdiagnose, as Apple asked.
      Record the FB numbers in your migration ticket — they are the only handle you have on any of
      these.

---

## 13. Quick reference: the one-page diff

For pasting into a migration ticket.

### Version floors

| | 26.0 | 26.4 | 27.0 | Xcode 27 | macOS 27 |
|---|---|---|---|---|---|
| Framework, `@Generable`, `Tool`, `Transcript` | ✅ | | | | |
| `supportsLocale(_:)` | ✅ | | | | |
| `contextSize`, `tokenCount(for:)` | | ✅ (`contextSize` back-deployed) | | | |
| Guardrail false-positive reduction | | ✅ | more in 27 | | |
| `LanguageModel` protocol, PCC, `ContextOptions`, Dynamic Profiles, `Attachment`, `LanguageModelError`, `ToolCallingMode`, `TranscriptErrorHandlingPolicy`, `Usage`, `Transcript.history`, Core AI, watchOS | | | ✅ | | |
| Evaluations framework | | | | ✅ | |
| New error types actually caught | | | | ✅ | |
| `fm` CLI | | | | | ✅ |

**TensorOps is a separate ladder:** 26.0 intro · 26.1 bfloat · **26.3** cooperative tensors as matmul
inputs · **26.4** int4/int8. No 26.2 step in the ladder; the 26.6 SDK headers annotate the symbol as
26.2. Both true, different things.

### The four labels

| ADDITIVE | BEHAVIOURAL | RENAMED | WITHDRAWN |
|---|---|---|---|
| image input | the model was **rebuilt** (twice: 26.4, 27.0) | `GenerationError` → `LanguageModelError` **+ `SystemLanguageModel.Error` + `LanguageModelSession.Error`** | **custom LoRA adapters** |
| `PrivateCloudComputeLanguageModel` | guardrails moved | `.exceededContextWindowSize` → `.contextSizeExceeded` | `SystemLanguageModel.Adapter` |
| `LanguageModel` / `LanguageModelExecutor` | refusals shifted between two mechanisms | `.unsupportedGuide` → `.unsupportedGenerationGuide` | `.fmadapter` |
| Dynamic Profiles + `DynamicInstructions` | Apple's samples dropped proactive gating | `.assetsUnavailable` moved to `SystemLanguageModel.Error` | `xcrun ba-package foundation-models` |
| Skills + history modifiers (`utilities`) | availability over-reports `.appleIntelligenceNotEnabled` (**a defect**) | `.concurrentRequests` moved to `LanguageModelSession.Error` | Adapter Training Toolkit (stops at 26.0.0) |
| `SpotlightSearchTool` | `.permissiveContentTransformations` still doesn't cover `Generable` | `SamplingMode.top` → `.randomTopK` | `com.apple.developer.foundation-model-adapter` |
| `OCRTool` / `BarcodeReaderTool` (**in Vision**) | `.anyOf` still doesn't constrain | `SamplingMode.nucleus` → `.randomProbabilityThreshold` | `Transcript.CustomSegment` + `.updateCustomSegment(_:)` — gone in **beta 5** (§8.3) |
| `Response.usage`, `session.usage` | OS update invalidates Core AI specialization | `GenerationOptions(sampling:)` → `(samplingMode:)` | |
| mutable `session.transcript`, `Transcript.history` (typed `Transcript.HistoryView` as of beta 5, §4.9) | Simulator punches out to the host Mac | `LanguageModelSession(transcript:)` → `(profile:history:)` | |
| `toolCallingMode` | | `ImageReference.resolve(in:)` → `resolved(in:)` | |
| `TranscriptErrorHandlingPolicy` | | `.model(_:)` moved from `utilities` into the framework | |
| `ContextOptions` / `reasoningLevel` | | `SkillActivations` lost `RandomAccessCollection` | |
| Evaluations framework, `fm` CLI, Core AI, watchOS | | | |

### Ten sentences a migrating team should be able to recite

1. The error taxonomy changes **when you change Xcode**, not when you change code.
2. The on-device model changed **twice** since 26.0, and there is **no version pinning API**.
3. `.permissiveContentTransformations` **does not apply to guided generation**.
4. A refused **string** response is a successful response containing an apology.
5. `OCRTool` and `BarcodeReaderTool` are in **Vision**, not FoundationModels — and `OCRTool` has no
   watchOS.
6. The Siri-availability coupling is a **defect Apple acknowledged**, not a gate to design around.
7. PCC eligibility is a **business** gate (Small Business Program + <2M lifetime first-time
   downloads + entitlement), not a technical one.
8. Custom adapters are **gone**; the replacement is a different framework and a different shape.
9. The **Simulator punches out to your Mac** — behavioural results need a physical device.
10. The Python SDK is a **26-generation artifact**: no PCC, no profiles, no `LanguageModel` protocol.

---

## 14. Sources and evidence ledger

This guide makes a lot of claims. Here is where each class of them comes from, in the series'
precedence order, so you can weigh anything you want to re-verify.

### 14.1 Precedence used

1. **Apple sample-code projects** — compiling first-party code. Strongest evidence available short of
   the headers.
2. **Headers / SDK / shipping repository source.**
3. **Apple documentation pages**, including Technical Notes.
4. **Apple-staff answers on the Developer Forums.** Where a forum answer from Apple staff conflicts
   with a WWDC session, the forum wins and this guide says so.
5. **WWDC / Tech Talk transcripts.** Spoken narration; identifiers are described, not dictated.
6. **Community repositories and blog posts** — always attributed as community-measured.

### 14.2 Apple sample-code projects used

| Sample | Vintage | What it settled here |
|---|---|---|
| **Origami: Crafting a dynamic tutorial for Apple Intelligence** (61 Swift files, iOS 27) | ✅ 2026 | The real `DynamicProfile` shape (`some DynamicProfile`, `Profile{}.model(_:)`, `.temperature(1.0)`, `.historyTransform` taking `[Transcript.Entry]`); `LanguageModelSession(profile:history:)`; the complete `LanguageModelError` case list; `SystemLanguageModel.Error` checked first; `GeneratedContent.ParsingError`; the **absence** of any availability gate; the zero-partials streaming guard; `Attachment(_:).label(_:)`; `SystemLanguageModel()` bare init as 2026 house style. |
| **Searching indexed content with natural language** (the hiking-trails app, 6 Swift files, iOS 27) | ✅ 2026 | Independently confirms the same five `LanguageModelError` cases and the same error-ordering file; `SpotlightSearchTool(configuration:)` shape; model-facing name `spotlight_search`; **no entitlement required**. |
| **Book Tracker: Using Evaluations…** (20 Swift files, macOS 27) | ✅ 2026 | The Evaluations surface; **Cohen's κ is hand-rolled in the sample, not shipped by the framework**. |
| **Generate dynamic game content with guided generation and tools** (`FoundationModelsCoffeeGame`) | ⚠️ **iOS 26 leftover** — `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, never refreshed | Used **only** as the "before" column: the proactive `availability` switch in §6.4, and the 26-era `LanguageModelSession(transcript:)` label. **Do not cite it as 2026 API.** |
| **Bringing advanced speech-to-text capabilities to your app** (`SwiftTranscriptionSampleApp`) | ⚠️ **WWDC25 leftover** | Not used in this guide. Named here so nobody mistakes it for 2026 evidence. |

⚠️ Also verified this cycle and worth repeating: **`coreai` has zero sample-code projects.**

### 14.3 Repositories read

| Repo | Commit / tag | Used for |
|---|---|---|
| `apple/foundation-models-utilities` | `376ca60`, tag `1.0.0-beta3`, 2026-07-10 | Platform floor (27.0 everywhere); Skills and history modifiers; `ChatCompletionsLanguageModel` and its `v1` defect; the commit message that doubles as a beta1 → beta3 framework changelog (§7.3, §7.4); the `from: "1.0.0"` resolution trap; the framework symbols incidentally revealed by compiled use. |
| `apple/python-apple-fm-sdk` | HEAD `e868e60` | The whole of §9: platform requirements, `FM_HAS_MACOS_27_SDK` gating, token-count 26.4 guard, the four defects, the limitations table. |
| `ml-explore/mlx-swift-lm` | `main` (3.x) | `MLXFoundationModels` gating on `canImport(FoundationModels, _version: 2)`; the empty-library behaviour; commit `3cbf928` (dual-SDK CI); `2a76e56` (SamplingMode rename); `1c86cc1` (`updateUsage` symbol mismatch). |
| `apple/coreai-models` | — | `CoreAILanguageModel`'s conformance, used to cross-check the `LanguageModel` protocol members. |

### 14.3.1 SDK interfaces read (captured 2026-07-29)

| Interface | Used for |
|---|---|
| `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface` (first read from Xcode 27.0 beta `27A5228h`, module `2.0.62.1.402`; on disk since 2026-08-20: beta 5 `27A5237l`, macOS 27.0 SDK, `-user-module-version 2.0.68.1.401`) | The `LanguageModel` / `LanguageModelExecutor` protocol text (§4.3); the nine `LanguageModelError` cases (§7.1); the adapter `obsoleted: 27.0` annotations (§8.1); `Usage` (§4.7); `ContextOptions` (§4.11); the policy setter spellings (§4.10); the sampling renames at header level (§7.3); the un-deprecated `transcript:` initializer (§7.5); the `resolve(in:)` contradiction (§7.6); the `contextSize` back-deploy fallback returning 4096 (§1.1) |
| `notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface` (`MacOSX26.5.sdk`, module `1.5.2`) | The BEFORE side throughout; the absence of any adapter deprecation in the 26-era SDK (§8.1) |
| `notes/sdk-interfaces/Vision-27.0-macos.swiftinterface`, `CoreSpotlight-27.0-macos.swiftinterface` | Negative results: `OCRTool` / `BarcodeReaderTool` / `SpotlightSearchTool` are **not in the main module interfaces** — they live in cross-import overlays (§4.6) |
| `notes/sdk-interfaces/_Vision_FoundationModels-27.0-macos.swiftinterface`, `_CoreSpotlight_FoundationModels-27.0-macos.swiftinterface` (captured 2026-07-29, same beta; recaptured 2026-08-20) | The overlay declarations themselves: both Vision tools' config/`Arguments`/opaque `Output` and the watchOS asymmetry (§4.6, gap 2 — resolved); `SpotlightSearchTool`'s full configuration surface (§4.6) |

### 14.4 Apple documentation pages

- `/documentation/updates/foundationmodels` — the June 2026, March 2026 and February 2026 sections,
  quoted verbatim in §3, §4 and §9.
- `/documentation/foundationmodels` — the framework index and topic map, used for the additive
  inventory in §4.
- `/documentation/foundationmodels/systemlanguagemodel` — the three model versions; the availability
  enum; `Guardrails`; `contextSize`'s back-deployment attribute.
- `/documentation/foundationmodels/languagemodelsession/generationerror` — the deprecation notice
  quoted at the top of this guide and in §7.1.
- `/documentation/foundationmodels/languagemodelerror` and siblings — the case tables in §7.1.
- `/documentation/foundationmodels/generationoptions` (+ `SamplingMode`, `ToolCallingMode`) and
  `/documentation/foundationmodels/contextoptions` — §4.8, §4.11, §7.3.
- `/documentation/foundationmodels/transcripterrorhandlingpolicy` — §4.10.
- *Adding server-side intelligence with Private Cloud Compute* — the comparison table and quota API
  in §4.2.
- *Analyzing images with multimodal prompting* — the `BarcodeReaderTool` example in §4.6 and the
  `ImageReference` usage in §7.6.
- *Improving the safety of generative model output* — the guardrails/refusal distinction in §6.2–6.3.
- *Updating prompts for new model versions* — the version-gated prompt pattern in §3.2.
- **TN3193**, *Managing the on-device foundation model's context window* — the 4096 figure, the
  `tokenCount(for:)` coverage, the six mitigations, and the `exceededContextWindowSize` spelling in
  §7.2. Slug: `…tn3193-managing-the-on-device-foundation-model-s-context-window`.
- `https://developer.apple.com/private-cloud-compute/` — the three eligibility criteria in §4.2.
  ⚠️ The `…/apple-intelligence/private-cloud-compute/` path 404s.
- `/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes#Foundation-Models` — the PCC
  Simulator known issue (177684296).

### 14.5 Developer Forums threads cited

Every thread below was fetched in full; Apple-staff replies are quoted verbatim where used.

| Thread | Subject | Used in |
|---|---|---|
| **829108** | `compatibleAdapterNotFound` — **first adapter-discontinuation statement** | §8.1 |
| **831314** | Adapter Training Toolkit for OS 27? — **second adapter-discontinuation statement** | §8.1 |
| **831404** | Cannot pattern-match `LanguageModelError` from a stream — **Apple's four-clause catch**, and **the Simulator punch-out explanation** | §7.1, §6.9 |
| **831998** | `PrivateCloudComputeLanguageModel` fails to respond — **PCC broken in Simulator**, entitlement `fatalError`, error 1046 | §4.2, §6.9 |
| **832534 / 833651** | `SpotlightSearchTool` description vs JSON Schema mismatch — **DTS-confirmed known issue** | §4.6 |
| **832910** | Model variation within the same iOS — **AFM 3 Core vs AFM 3 Core Advanced**, with the device list | §3.3 |
| **833575** | FM in extensions — out-of-process, XPC restriction | §6.8 |
| **833626** | Dynamic Profile switching and context reconciliation — `historyTransform` recommendation | §7.7 |
| **833642** | The densest Apple answer in the corpus — 4K context, **no version pinning API**, image behaviour, concurrency | §3.1, §4.1, §6.8 |
| **833657** | *"All on-device Apple Foundation Models are powered by Core AI."* | §5.4 |
| **833666** | Background NPU priority — *"There's no entitlement or API to influence this."* | §6.8 |
| **833692** | Strict RAG — *"You can use `.toolCallingMode` with `DynamicProfiles`."* | §4.8 |
| **833706** | `summarizeHistory` internals — **destroys tool-call metadata** | §7.7 |
| **833729** | **Evaluations is Swift-only** | §5.1 |
| **834149** | TTS expressive voices — **no new speech API** | §8.2 |
| **834652** | watchOS + PCC pairing (community self-answer, no Apple reply) | §4.12 |
| **835165** | `SkillActivation` fails to build on Xcode 26 | §10 |
| **835211** | Availability tied to Siri toggle (**unanswered**) | §6.5 |
| **835777** | Guardrails changed under a shipping app; `.permissiveContentTransformations` and its `Generable` limitation | §6.2 |
| **835897** | PCC eligibility / lifetime downloads | §4.2 |
| **835927** | Context-management wrapper — **mutable `transcript` + `history` in iOS 27** | §4.9, §7.7 |
| **835974** | PCC quota is coarse (FB23378161) | §4.2 |
| **835987** | **watchOS 27 Beta 2 `CoreImage` build break — "This is a known bug"** | §10 |
| **836264** | `MLXFoundationModels` not findable — answered: `mlx-swift-lm` PR #334 | §10 |
| **836285** | `com.apple.SensitiveContentAnalysisML error 15` | §6.9 |
| **836673** | **iOS 27 model-level refusal regression** (FB23513774, no Apple reply) | §6.3 |
| **836760** | **Apple Frameworks Engineer: FM *should* be available without Siri AI — file a bug** | §6.5 |
| **836810** | No Required Device Capability for Apple Intelligence; *"check availability before anyone agrees to pay"* | §6.5 |
| **837226** | `SpotlightSearchTool` not invoked; `GenerationOptions(toolCallingMode: .required)` in the wild (FB23643759) | §4.6, §4.8 |
| **838444** | `ChatCompletionsLanguageModel` hardcoded `v1` (FB23837262) | §5.3 |
| **838613** | Image input and localisation — Apple redirects to Vision | §4.1 |
| **838904** | `SpotlightSearchTool` model-catalog error — *"Whelp, that's totally a bug. 🐛"* | §4.6 |
| **812501** | **`.anyOf` reproduced-broken by Apple**; `Tool.parameters` computed once | §6.6 |
| **817502** | `tokenCount(for:)` shipped in 26.4; TN3193 pointer | §1.1 |
| **820819** | iOS 26.4 regressions; `LanguageModelFeedback` | §6.2 |
| **823001 / 823148** | Adapter disk leak and the `ba-package` pipeline (26.x, historical) | §8.1 |

### 14.6 Transcripts

- **WWDC26 241**, *What's new in Foundation Models* — the rebuilt model; image input; PCC; the
  `LanguageModel` protocol; `usage`; system tools; Dynamic Profiles; Evaluations; `fm`; the Python
  SDK; open source.
- **WWDC26 319**, *Private Cloud Compute* — the on-device/PCC comparison table; `contextSize`;
  quota UX; *"data, not vibes"*.
- **WWDC26 334**, *Foundation Models on macOS* — the `fm` CLI; the Python SDK; the prompt-length
  empirical finding used in §6.1.
- **WWDC26 242**, *Build agentic app experiences* — `transcriptErrorHandlingPolicy` as a modifier;
  modifiers living partly in `utilities`.
- **Meet with Apple 205**, the code-along — the **iOS 26 baseline**; used only as a "before" column.
- **Tech Talk 111432**, *Accelerate your machine learning workloads with the M5 and A19 GPUs* — the
  TensorOps ladder in §2.

⚠️ One transcript oddity, flagged so nobody repeats it: session 241 literally says *"Our **2027**
release"* while every OS reference in the same session is iOS 27 / macOS 27 / watchOS 27, at WWDC26.
Either Apple internally calls the OS-27 cycle "the 2027 release" or it is a transcription artifact.
**Do not write "2027 release" in a migration doc.** Write iOS 27 / macOS 27.

### 14.7 Community-measured claims, explicitly labelled

Everything in this category is attributed inline in the body as well; collected here so it is easy to
discount if you want only first-party evidence.

| Claim | Attribution |
|---|---|
| `contextSize` reportedly returns **8192** on iOS 27 where 26 returned 4096 — **RETIRED historical claim; never reproduced** | Community source comment in a now-unavailable third-party app. Apple's Group Lab 8121 summary documents **4096, shared input+output**, joining session 319, the PCC article, the repo's simulator measurement, the 27.0 interface fallback, and repeated physical-iPhone measurements. Read `contextSize` at runtime. §1.1 |
| Core AI first-load of a 3 GB model at **194 seconds** on iPhone | Community-measured. §6.10 |
| Foundation Models may downsample images to **896 px** on the longest dimension | Developer inference in thread 838613. **Never Apple-confirmed.** §4.1 |
| Grammar-constrained decoding (`@Generable`) is unavailable on GPU-pipelined Core AI bundles because logits are not exposed | Community-measured. §4.3 |
| A watchOS 27 device also needs a paired iPhone with Apple Intelligence enabled to use PCC | Forum OP self-answer, no Apple reply. §4.12 |
| PCC context window = **32K** | Apple's own PCC article and session 319 both state 32K, so this one is first-party; a widely-quoted forum reply asserting 32K is **not** Apple and should not be cited as the source. §4.2 |

### 14.8 Open gaps declared in this guide

Collected so a future pass can close them. Each is a 🔴 **GAP** in the body with a stated safe default.

| # | Unknown | What would resolve it | § |
|---|---|---|---|
| 1 | What actually differs between **AFM 3 Core** and **AFM 3 Core Advanced**, and whether any API reports the tier | An Apple doc page or a `SystemLanguageModel` property | §3.3 |
| 2 | ~~The `Arguments` / `Output` associated types of `OCRTool` and `BarcodeReaderTool`, and the `Barcode` type~~ ✅ **RESOLVED 2026-07-29** — the `_Vision_FoundationModels` overlay interface was captured: `Arguments` is a Generable struct with no named public properties, `Output` is the opaque `some PromptRepresentable` return of `call`, and no public `Barcode` type exists | — | §4.6 |
| 3 | Why `BarcodeReaderTool` lists watchOS and `OCRTool` does not | An Apple statement; the difference itself is verified | §4.6 |
| 4 | ~~Whether the two `toolCallingMode` surfaces are the same type~~ ✅ **RESOLVED** — same type (SDK, 2026-07-29). Which wins: options-over-profile is device-confirmed **only** in the profile-allows → options-disallow direction (iPhone 15 Pro, 2026-08-20); 🟡 the reverse (profile-disallows → options-require) is an inference from a `contextSizeExceeded` fingerprint — the probe's catch path recorded no `toolCalled`/`toolRan` discriminators | Next device run of the updated probe, which now records the discriminators | §4.8 |
| 5 | ~~Whether the policy setter is a session property or a modifier~~ ✅ **RESOLVED 2026-07-29** — both exist (`27.0:1925-1932, 982`). ~~Still open: the default~~ ✅ **RESOLVED, probe-verified on sim + iPhone 15 Pro** — initial value is `nil`, and `nil` behaves like `.revertTranscript` (`fm.transcript-policy-nil-default`) | — | §4.10 |
| 6 | ~~Which `includeSchemaInPrompt` wins when set both on `ContextOptions` and on `respond(…)`~~ ✅ **RESOLVED, probe-verified on sim + iPhone 15 Pro** — one knob, two spellings: both record identically; default records `Optional(true)` (`fm.includeSchemaInPrompt-recording`) | — | §4.11 |
| 7 | ~~`fm schema object`'s argument grammar, and the full `fm` subcommand list~~ ✅ **RESOLVED 2026-08-17** — `/usr/bin/fm` run on macOS 27 beta 5 (`26A5406e`); the full help surface is captured as `notes/sdk-interfaces/fm-help-27.0.txt` (see [Part 5 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md)). Runtime-only residue: interactive slash commands, refusal/error exits, and field-level `serve` compatibility | Focused live calls against later macOS 27 seeds | §5.2 |
| 8 | Where the open-sourced core Foundation Models framework lives | The repository appearing | §5.5 |
| 9 | ~~The successor to `GenerationError.decodingFailure`~~ ✅ **RESOLVED 2026-07-29** — the header names `GeneratedContent.ParsingError` (`27.0:3555-3558`); runtime throws it on truncated structured output (code 1), confirmed on sim and iPhone 15 Pro (`fm.parsingError-thrown`; see 17.3 §4.4) | — | §7.1 |
| 10 | ~~Whether `LanguageModelSession(transcript:)` is formally deprecated~~ ✅ **RESOLVED 2026-07-29** — it is not; no deprecation in the 27.0 interface (`27.0:41`) | — | §7.5 |
| 11 | ~~The exact declarations of `ImageReference.resolve(in:)` vs `resolved(in:)`~~ ✅ **RESOLVED 2026-09-07** — current docs and beta 5 agree on `resolved(in: some Sequence<Transcript.Entry>)`; beta 4's `resolve(in: Transcript)` remains a historical toolchain difference | — | §7.6 |
| 12 | Whether the Python SDK's tool calling is current (README omits it; the session claims it) | A README update, or reading `tests/test_tool.py` | §9 |
| 13 | Current beta status of the watchOS `CoreImage` break, the `SkillActivation` Xcode 26 failure, PCC-in-Simulator, and the `updateUsage` symbol mismatch | Re-running each reproduction on the current beta | §10.2 |
| 14 | Whether the Siri-availability coupling is fixed | A release note, or the symptom disappearing | §6.5 |
| 15 | Whether the XPC restriction on some extensions also blocks `SystemLanguageModel` | Apple answering the follow-up on thread 833575 | §6.8 |
| 16 | An end-to-end LoRA → Core AI / Core ML migration recipe | An Apple article or sample | §8.1 |

### 14.9 Where to go next in this part

| If your next question is… | Go to |
|---|---|
| "I ship a `.fmadapter`. What now?" | [17.2 — The adapter sunset](02-adapter-sunset.md) |
| "Which `catch` fires, exactly?" | [17.3 — Error taxonomy migration](03-error-taxonomy-migration.md) |
| "I must build against both 26 and 27 SDKs." | [17.4 — Building for two SDKs](04-dual-sdk-builds.md) |
| "Should my Core ML model move to Core AI?" | [17.5 — Core ML to Core AI](05-coreml-to-coreai.md) |
| "My `.aimodel` assets / `mlx-swift-lm` pin broke." | [17.6 — Toolchain and asset compatibility](06-toolchain-and-asset-compatibility.md) |
| "How do I actually use Dynamic Profiles?" | [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) |
| "How do I pick a backend?" | [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) and [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) |
| "How do I build the regression suite this guide keeps telling me to build?" | [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) |

[^supports-locale-floor]: The authoritative Xcode 26.5 interface places [`SystemLanguageModel.supportsLocale(_:)`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface#L572-L591) in the OS 26.0 declaration; the following extension is the distinct OS 26.4 context-introspection surface.
[^metal-auxiliary-plane]: Apple, [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor), including the scale-plane descriptor and block factors introduced for the Metal 27 tensor surface.
[^metal-auxiliary-map]: Apple, [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), the descriptor map that attaches auxiliary planes to an `MTLTensor`.
[^metal-low-bit-types]: Apple, [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype), including the Metal 27 int2, FP4, FP8, and E8M0 datatype cases.
[^wwdc330]: [WWDC26 session 330 transcript, lines 27–78](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L27-L78), which introduces 2-bit/4-bit/8-bit formats, E8M0 scale planes, block factors, and automatic dequantization.

---

*Last verified against sources dated 2026-07-27; forum status re-checked 2026-07-29; the 27.0 beta
SDK interfaces (Xcode 27.0 beta `27A5228h`) read 2026-07-29, which closed or narrowed five of the
sixteen gaps in §14.8 and turned one into a live docs-vs-SDK contradiction (§7.6). Every symbol in
this guide carries a marker; where a marker says 🟡 or 🔴, that is a statement about our evidence, not
a hedge about the concept. If you can close one of the remaining gaps in §14.8 with an overlay dump
or a device test, that is the highest-value contribution anyone can make to this part of the series.*
