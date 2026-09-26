# Image input, and what the model cannot do with pixels

**Part 2 — Foundation Models: the everyday API · Reference 05**
**Status:** beta-era material. Last verified against the corpus on 2026-07-27.

---

## What this covers

The 2026 release gave the on-device model eyes. You put an image into a prompt the same way you put
a string into a prompt — `Attachment(image)` inside a `Prompt { }` builder — and the model can answer
questions about it. This guide covers the whole surface: the `Attachment` type and every source it
accepts, orientation (which is *your* problem and is the single most common way to get silently wrong
answers), labels and `ImageReference` for keying structured output back to specific images, the
transcript types that images turn into, the Python SDK's parallel API, and the platform asymmetry
that bites you the moment your Swift code leaves Darwin.

The most useful section is **§9 — what the model cannot do with pixels**. The model reliably *names*
what is in an image and unreliably *locates* it. Spatial work belongs to Vision or to a real
detection/segmentation model. If you read only one section, read that one.

## Version floor

Everything in this guide is **iOS 27.0 / iPadOS 27.0 / macOS 27.0 / visionOS 27.0 / watchOS 27.0,
all still marked Beta**. There is no back-deployment. `Attachment`, `ImageAttachmentContent`,
`ImageReference`, `Transcript.AttachmentSegment` and `Transcript.ImageAttachment` are all new symbols
in the 2026 wave — none of them exists in 26.0, 26.2 or 26.4.

> ✅ **VERIFIED** — the Apple documentation index for FoundationModels groups these four under a
> topic literally named **"Prompt Attachments"** — *"Analyzing images with multimodal prompting;
> `Attachment`; `ImageAttachmentContent`; `ImageReference`"* — and every one of them carries the
> availability string `iOS 27.0+ Beta, … watchOS 27.0+ Beta`.
> (`/documentation/foundationmodels`, `/documentation/foundationmodels/attachment`, harvested
> 2026-07-27.)

The `FoundationModels` framework itself is `iOS 26.0+ … visionOS 26.0+, watchOS 27.0+ Beta`. So a
26.x deployment target still compiles — you just have to `#available`-gate every line below. See
[Part 1 · platform and version gating](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).

## What you need

- Xcode 27 (the macOS 27 SDK — this is a *build-time* gate, not just a runtime one; §11 shows what
  happens to the Python SDK when you get it wrong)
- A **physical device on 27.0**. The simulator punches out to the host macOS to run the model, so an
  Xcode 27 SDK on a macOS 26 host produces meaningless errors. This is the single largest source of
  phantom bug reports in this stack; it is covered in
  [availability, errors and guardrails](06-availability-errors-and-guardrails.md).
- Familiarity with `LanguageModelSession` and the prompt builders —
  [sessions and prompting](01-sessions-and-prompting.md).

---

## Contents

1. [The symbol inventory, and where each one came from](#1-the-symbol-inventory-and-where-each-one-came-from)
2. [The five-minute version](#2-the-five-minute-version)
3. [`Attachment` in depth: initializers, sources, and one API-spelling conflict](#3-attachment-in-depth-initializers-sources-and-one-api-spelling-conflict)
4. [Any size, any aspect ratio — and what that costs you](#4-any-size-any-aspect-ratio--and-what-that-costs-you)
5. [Orientation is your problem](#5-orientation-is-your-problem)
6. [Labels and `ImageReference`: keying output back to inputs](#6-labels-and-imagereference-keying-output-back-to-inputs)
7. [The transcript side: `AttachmentSegment`, `ImageAttachment`, and the cost of remembering](#7-the-transcript-side-attachmentsegment-imageattachment-and-the-cost-of-remembering)
8. [Structured output from images, and the two Vision-backed tools](#8-structured-output-from-images-and-the-two-vision-backed-tools)
9. [What the model cannot do with pixels](#9-what-the-model-cannot-do-with-pixels)
10. [Which backends accept images](#10-which-backends-accept-images)
11. [Python, and the `fm` CLI](#11-python-and-the-fm-cli)
12. [Gotcha table, open gaps, and sources](#12-gotcha-table-open-gaps-and-sources)

---

## 1. The symbol inventory, and where each one came from

Before any code, here is every symbol this guide touches, with its evidence marker. Nothing below is
written from memory; if a spelling is inferred rather than read, it says so.

| Symbol | Declaration | Floor | Evidence |
|---|---|---|---|
| `Attachment` | `struct Attachment<Content>` | 27.0 | ✅ Apple symbol page |
| `Attachment.init(_:orientation:)` | *"Creates an attachment from a …"* | 27.0 | ✅ Apple symbol page |
| `Attachment.init(imageURL:orientation:)` | *"Creates an attachment from a file URL pointing to an image."* | 27.0 | ✅ Apple symbol page + Apple's Python-SDK Swift shim |
| `Attachment.label(_:)` — stable handle for `ImageReference`; generic tool calls can still run without one (§6.4) | `func label(_:) -> Attachment` | 27.0 | ✅ Apple symbol page + Apple sample + 2026-08-20 device probe |
| `ImageAttachmentContent` | `struct ImageAttachmentContent : Sendable, Equatable` | 27.0 | ✅ symbol page + SDK-verified (`FoundationModels-27.0-macos.swiftinterface:2850-2852`) — **deliberately opaque**: no public members beyond `==`; it exists as the phantom `Content` of `Attachment<ImageAttachmentContent>`, whose four inits are constrained on it (`:2855-2860`); **never appears at a call site in any Apple sample** |
| `ImageReference` | `struct ImageReference`, conforms `Generable` | 27.0 | ✅ Apple symbol page + `Origami/Brainstorm/ImageAnalysis.swift:11-21` |
| `ImageReference.attachmentLabel` | `var attachmentLabel: String` | 27.0 | ✅ Apple symbol page + `Origami/Brainstorm/BrainstormModel.swift:142-144`, `:168-171` |
| `ImageReference.resolved(in:)` | `func resolved(in:) -> Transcript.ImageAttachment?` | 27.0 | ✅ Apple symbol page |
| `ImageReference.resolve(in:)` | *(Deprecated)* | 27.0 | ✅ Apple symbol page |
| `Transcript.ImageAttachment` | `struct ImageAttachment: Equatable, Sendable` | 27.0 | ✅ Apple symbol page |
| `Transcript.AttachmentSegment` | `struct AttachmentSegment`, `init(id:content:label:)` | 27.0 | ✅ Apple symbol page + Apple's `SKILL.md` |
| `Transcript.Attachment` | enum with `case image(ImageAttachment)` | 27.0 | ✅ Apple's `SKILL.md` in `foundation-models-utilities` |
| `Transcript.Segment.attachment` | new enum case | 27.0 | ✅ Apple symbol page (the `Segment` case list) |
| `LanguageModelCapabilities.Capability.vision` | *"The capability to accept image inputs in prompts."* | 27.0 | ✅ Apple symbol page |
| `OCRTool`, `BarcodeReaderTool` | Vision-provided `Tool`s | 27.0 | ✅ Apple docs + WWDC26 session 241 |
| `fm respond --image` | CLI flag | macOS 27 | 🟡 **RECONSTRUCTED** — only the *semantic* name ("the image option") was spoken |

Two of those deserve immediate expansion.

**`Attachment` is generic.** The declaration is `struct Attachment<Content>`, not `struct
ImageAttachment`. Today the only `Content` anyone has documented is image content
(`ImageAttachmentContent`), and Apple's own framing in the utilities package is unambiguous —
the transcript-side enum is

```swift prelude:guide-context
public enum Attachment: Sendable, Equatable {
  case image(ImageAttachment)
}
```

— a one-case enum, which is exactly the shape you use when you expect a second case later. Write
your `switch` over `Transcript.Segment` and `Transcript.Attachment` with a `@unknown default` from
day one. (✅ verified: `skills/foundation-models-language-model-protocol/SKILL.md:455-463` in
`github.com/apple/foundation-models-utilities`.)

**`Attachment` conforms to `PromptRepresentable` *and* `InstructionsRepresentable`.** That is on the
symbol page and now ✅ **SDK-verified** — `extension Attachment : PromptRepresentable,
InstructionsRepresentable` with both representation properties
(`FoundationModels-27.0-macos.swiftinterface:2838-2847`) — and it means an attachment is legal
inside an `Instructions { }` block, not only a `Prompt { }` block.

> 🔴 **GAP — images in instructions.** The conformance compiles (SDK-verified above), but no source
> in the corpus shows an image attached to `Instructions` rather than a `Prompt`, and nothing
> describes how such an image interacts with the instruction-caching that makes instructions cheap
> to re-send. The semantics are undocumented. To resolve: an Apple doc page for `Attachment`'s
> `InstructionsRepresentable` conformance, or an empirical `usage`-property comparison between an
> image in instructions vs. the same image in a prompt on a device running 27.0.
> **Safe default:** attach images to the `Prompt`, never to `Instructions` — every source in the
> corpus does it that way, and prompt-side attachment leaves the cached instruction prefix
> byte-stable (§4.3 of guide 3.1 is why that matters).

---

## 2. The five-minute version

The API really is *"a natural extension of the existing prompt builders"* — that is Apple's own
phrasing from WWDC26 session 241, and it is accurate. You do not construct a request object, you do
not pick an encoder, you do not resize anything.

```swift compile:27
import FoundationModels
import CoreGraphics

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
func describe(_ image: CGImage) async throws -> String {
    let session = LanguageModelSession()
    let response = try await session.respond {
        "Describe this image:"
        Attachment(image)
    }
    return response.content
}
```

> ✅ **VERIFIED** — this is Apple's own snippet, from
> `/documentation/foundationmodels/analyzing-images-with-multimodal-prompting`:
> ```swift
> let response = try await session.respond {
>     "Describe this image:"
>     Attachment(image)
> }
> ```

Two images, each labelled, compared in one call — also Apple's, verbatim:

```swift prelude:guide-context
Prompt {
    "Compare these two images:"
    Attachment(firstImage)
        .label("image-0")
    Attachment(secondImage)
        .label("image-1")
}
```

And the full function form, which is the one worth memorising because it shows the orientation
parameter *and* Apple's own comment explaining when you need it:

```swift compile:27 imports:FoundationModels,CoreGraphics
func compareImages(imageOne: CGImage, imageTwo: CGImage) async throws -> String {
    let session = LanguageModelSession()
    let response = try await session.respond {
        "Compare these two images by using three bullet points:"

        Attachment(imageOne)

        // When the image doesn't have a rotation applied, like when you get a
        // image from the `AVFoundation` framework, use orientation to perform
        // a transform before sending it to the model.
        Attachment(imageTwo, orientation: .right)
    }
    return response.content
}
```

(✅ verbatim from the same Apple article, comment typo and all.)

Note what is *absent* from all three snippets: no availability check on `SystemLanguageModel`, no
resize, no format conversion, no error handling. The resize and the format conversion you genuinely
do not need (§3.4). The other two you do — but be aware that Apple's own 2026 sample code has
changed its mind about *how*:

> ✅ **VERIFIED** — Origami **never calls `SystemLanguageModel.availability`, never uses an
> `#available` guard, and never gates UI on model readiness.** It relies entirely on catching
> `SystemLanguageModel.Error` at use time and rendering a `displayMessage`
> (`Origami/Models/Error+DisplayMessage.swift:12-36`). The same reactive-only posture appears
> independently in the Spotlight sample. The iOS 26 coffee-game sample gated proactively; the 2026
> samples do not.

Treat that as Apple's current house style, not as permission to skip the check. Reactive catching is
mandatory — an image prompt can fail for availability reasons on any turn. Proactive gating is what
lets you hide a camera button that will never work. Do both; the error taxonomy and the ordering that
matters (`SystemLanguageModel.Error` is tested *before* `LanguageModelError`) are in
[reference 06](06-availability-errors-and-guardrails.md).

---

## 3. `Attachment` in depth: initializers, sources, and one API-spelling conflict

### 3.1 The two initializers

```swift illustrative
struct Attachment<Content>                  // iOS 27.0+ Beta
// Conforms: Copyable, Escapable, InstructionsRepresentable, PromptRepresentable

init(_:orientation:)                        // from an in-memory image
init(imageURL:orientation:)                 // from a file URL pointing to an image
func label(_:) -> Attachment                // assigns a label; returns a new Attachment
```

> ✅ **VERIFIED** — `/documentation/foundationmodels/attachment`. Apple's own one-line summaries:
> *"Use `Attachment` to include media such as images alongside text in your prompts and
> instructions."* and *"Labels help the model identify specific attachments when making tool
> calls."*

The first initializer's argument is **unlabelled**. That matters, because a widely-mirrored
paraphrase of Apple's multimodal article writes it as `Attachment(image: image)`, which does not
match the symbol page and does not match Apple's shipping sample code.

> ✅ **VERIFIED spelling.** The symbol page declares `init(_:orientation:)` and a separate
> `label(_:)` method, while Apple's shipping Origami sample writes
> `Attachment(image).label(idString)`. Use `Attachment(image)` and `.label("…")`; do not infer an
> `image:` initializer label or initializer-level `label:` parameter from retired paraphrases.

### 3.2 What you can hand it

Apple's documentation names four sources:

> ✅ **VERIFIED**, verbatim from the multimodal-prompting article:
> *"The framework supports several image types to include in your prompts, like `CGImage`, `CIImage`,
> `CVPixelBuffer`, and image URLs. Use a URL whenever your image comes from a file and verify that it
> points to an actual image. **The framework infers whether a URL represents an image based on its
> `UTType`.** If your app captures images or processes video streams, use `CVPixelBuffer`."*

WWDC26 session 241 read out a longer list — the same four, plus `UIImage` and `NSImage`:

> ✅ **VERIFIED** (WWDC26 241, spoken): `UIImage`, `NSImage`, `CGImage`, "Core Image types",
> "CoreVideo Pixel Buffers", and file URLs.

And the `UIImage` / `NSImage` claim is not just narration — Apple's Origami sample passes them
directly:

```swift prelude:guide-context
// Origami/Models/DataModels/Photo.swift:77-91 — Apple sample source, verbatim
func toPrompt() async throws -> Prompt {
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else {
        return Prompt {}
    }
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else {
        return Prompt {}
    }
    #endif
    let idImage = Attachment(image).label(idString)
    return Prompt {
        idImage
    }
}
```

Three things to steal from those fifteen lines:

1. **`Attachment(_:)` takes a `UIImage`/`NSImage` with no bridging step.** No `.cgImage` dance, no
   `ImageAttachmentContent` construction at the call site.
   > ⚠️ **Where those overloads live (2026-07-29).** The FoundationModels 27.0 beta interface
   > declares exactly **four** image inits on `Attachment<ImageAttachmentContent>` — `CGImage`,
   > `CIImage`, `CVPixelBuffer`, and `imageURL:`, each with `orientation:
   > CGImagePropertyOrientation? = nil` (✅ **SDK-verified**,
   > `FoundationModels-27.0-macos.swiftinterface:2855-2860`). There is **no `UIImage`/`NSImage`
   > overload in that module's interface** — yet Origami compiles `Attachment(image)` with both.
   > Both facts stand: the toolkit-type overloads must be supplied by an overlay outside the
   > FoundationModels module proper (they are not in the captured macOS interface), so if you are
   > auditing availability or writing cross-platform wrappers, the four-source list above is the
   > module's own contract and `UIImage`/`NSImage` acceptance is verified only at the call site.
2. **`Prompt {}` — the empty prompt — is a legal graceful-degradation value.** Apple returns it when
   decoding fails rather than throwing. That composes cleanly, because…
3. **…`Prompt` values splice into a `Prompt` builder, including arrays of them.** The same sample
   builds `var imagePrompts: [Prompt] = []`, appends one per photo, and then drops the whole array
   into the builder:

```swift illustrative
// Origami/Models/Orchestrator.swift:596-616 — Apple sample source, verbatim
var imagePrompts: [Prompt] = []
for photo in photos {
    imagePrompts.append(try await photo.toPrompt())
}
…
let prompt = Prompt {
    if let note {
        note
    }
    "I'm on section \(sectionIndex) step number \(stepNumber) of the tutorial. How does this look?"
    imagePrompts
    "For reference the step reads: \(stepContent ?? "")"
}
let stream = session.streamResponse(to: prompt)
```

That is the idiomatic pattern for "N images plus surrounding text, where N is dynamic": build
`[Prompt]`, splice. A shipping third-party app preserved in the
[frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) reaches the same shape with a `for`
loop directly inside the builder:

```swift prelude:guide-context
// Verified in a shipping app's source, not an Apple sample:
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private static func makeMultimodalPrompt(text: String, imagePaths: [String]) -> Prompt? {
    let images = imagePaths.compactMap { loadCGImage(path: $0) }
    guard !images.isEmpty else { return nil }
    return Prompt { for image in images { Attachment(image) }; text }
}
```

Both compile; pick whichever reads better. Three orderings are now attested and all three ship:
Apple's documentation snippets put the **text first**; Origami's coaching prompt puts the images
**in the middle**, sandwiched between the question and the reference text; and a shipping third-party
app puts the **images first**. Nothing in the corpus establishes that ordering changes quality — see
the open question in §12.

While you are in the builder, three further shapes are sample-verified: `if let` bindings (Origami's
optional `note`), string interpolation, and the `Prompt("…")` value initializer alongside the
`Prompt { }` builder.

> ✅ **VERIFIED** — `Origami/Models/Orchestrator.swift:596-616` for the array splice, the `if let`
> binding and the interpolation; `Photo.swift:77-91` for the empty `Prompt {}`.

### 3.3 The file-URL path

```swift prelude:guide-context
Attachment(imageURL: url)              // + optional orientation:
```

The URL initializer is the one Apple's own C bindings for the Python SDK use, so its spelling is
doubly attested:

```swift prelude:guide-context
// python-apple-fm-sdk → foundation-models-c/…/FoundationModelsCBindings.swift:31-48, verbatim
public func add(attachmentFromPath imagePath: String, label: String?) throws {
    // `Attachment` only exists in the macOS 27+ SDK
    #if FM_HAS_MACOS_27_SDK
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
      let url = URL(fileURLWithPath: imagePath)
      var attachment = Attachment(imageURL: url)
      if let label { attachment = attachment.label(label) }
      self.components.append(attachment)
      return
    } else { throw ComposedPromptError.unsupportedOS }
    #else
    throw ComposedPromptError.unsupportedSDK
    #endif
}
```

Two details worth extracting from Apple's own shim: `Attachment` is a **value type you can reassign**
(`var attachment = …; attachment = attachment.label(label)`), and the availability list includes
**watchOS 27.0** — so the `Attachment` type is present on watch, whatever the model situation there
turns out to be (§10).

> ⚠️ **SILENT FAILURE — a URL that isn't an image.** The framework decides whether a URL is an image
> *"based on its `UTType`"* (Apple's words). Apple's guidance is *"verify that it points to an actual
> image"* — which is a polite way of saying the framework will not do it for you. A `.txt` renamed to
> `.jpg`, a zero-byte file created by an interrupted download, or a security-scoped URL you forgot to
> `startAccessingSecurityScopedResource()` on macOS will not produce an exception at the `Attachment`
> call site; the attachment is built eagerly and the failure surfaces — if at all — as a model
> response that describes nothing, or as a generic `LanguageModelError`. **Validate before you
> attach:** check `UTType(filenameExtension:)` conforms to `.image`, or load the file yourself and
> attach the resulting `CGImage`. **There is no "attachment failed to decode" case in
> `LanguageModelError`.** The case list Apple's own shipping code switches over is `.timeout`,
> `.guardrailViolation`, `.refusal`, `.contextSizeExceeded` and `.unsupportedLanguageOrLocale` —
> nothing image-shaped — and the switch ends in `default: break`, so the enum is non-frozen and the
> provider-side cases in §10 (`.unsupportedCapability`, `.unsupportedTranscriptContent`) coexist
> outside that user-facing five. (✅ verified: `Origami/Models/Error+DisplayMessage.swift:12-36`,
> and independently in the Spotlight sample's near-identical file.)

### 3.4 What the framework does for you

> ✅ **VERIFIED**, marked IMPORTANT on Apple's own page: *"The framework performs the necessary
> **scaling and color conversions** before passing an image to the model, so you don't need to scale
> or convert images to different formats."*

So: no manual resize, no colour-space conversion, no `sRGB` pinning, no letterboxing. Contrast this
with what you have to do by hand when you drive a vision model through Core AI directly, where you
own the whole `CGContext` → normalized `NDArray` pipeline including the mean/std, the interpolation
quality, and the resize strategy. That contrast is the entire argument for using Foundation Models
for image *understanding* and Core AI for image *measurement*; §9 develops it.

---

## 4. Any size, any aspect ratio — and what that costs you

### 4.1 The promise

> ✅ **VERIFIED** (WWDC26 241, verbatim): *"The model supports **images in any size and aspect ratio,
> so you don't need to crop or pad to any particular shape**. Arbitrary image sizes are allowed, but
> bear in mind that **larger images will consume more tokens and incur more latency**."*

An Apple Frameworks Engineer restated the limits explicitly on the Developer Forums (thread 833642,
the single densest Apple answer in the corpus):

| Question | Apple's answer |
|---|---|
| Resolution limit | **None set.** The framework may resize. |
| Images per prompt | **Unlimited** — bounded only by the context window. |
| Formats | "Broad format support." |
| Does an image change which model serves the request? | **No.** An on-device call stays on-device. |

That last row is load-bearing and easy to get wrong: attaching an image does **not** silently
escalate you to Private Cloud Compute. If you called a session backed by `SystemLanguageModel`, the
image is processed on device. Your privacy story does not change when you add pixels.

### 4.2 The cost, and the fact that nobody has published it

Here is the honest state of the world:

> 🔴 **GAP — per-image token cost.** Apple has published **no** figure for how many context tokens an
> image consumes, no formula relating pixel dimensions to tokens, and no statement of whether the
> framework's internal resize is fixed-size or resolution-dependent. Session 241 says only "larger
> images will consume more tokens"; forum thread 833642 says only "no set resolution restriction …
> the framework may resize"; forum thread 833783 ("Image size, format, and background vs other
> VLMs") asked exactly this question and **was never answered**. To resolve this we would need
> either an Apple doc/technote on image tokenization, or a controlled experiment on a 27.0 device
> reading `response.usage` across a sweep of input resolutions. **Nobody in this corpus has run
> that experiment.** (The 27.0 beta interface was checked 2026-07-29: it contains no per-image
> token constant, no resize-policy symbol, and no image-related member on `Usage` — the answer is
> not in the SDK surface.)

Two numbers circulate. Neither is Apple's, and you should treat them accordingly.

- **896 px on the longest dimension.** Source: the original poster of forum thread 838613 (20 Jul
  2026), reasoning backwards from how badly the model's coordinate estimates behaved: *"Foundation
  Models downsamples images to 896px on longest dimension."* This is **developer inference, not
  Apple-confirmed**. It is plausible — 896 is a common ViT input edge, and Apple's own Core AI
  `ImagePreprocessor.gemma3` preset is `896×896` — but plausible is not verified, and the two facts
  are about different model families.
- **~576 tokens per image.** Historical source: the shipping community app preserved in the
  [frozen Noema research note](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md), which hardcodes
  `ImagePromptBudgetEstimator.promptTokensPerImage = 576` for its context meter, across *all* of its
  backends (llama.cpp, MLX, Core ML, Core AI and Foundation Models). It is a **generic VLM working
  figure, not an AFM measurement** — 576 is what you get from a 24×24 patch grid, e.g. 336 px at
  patch size 14, which is exactly the geometry of the SAM 3 image encoder in Apple's `coreai-models`
  repo (`336 // 14 = 24`, `24² = 576`). Useful as an order of magnitude for a UI meter. Not a fact
  about the on-device Apple model.

**What to do instead of trusting either number.** On a 4,096-token on-device context window, an
image in the low hundreds of tokens is not a rounding error — a handful of photos can eat half your
budget before the user types anything. So:

1. Read `response.usage` and `session.usage` after every multimodal turn and log the delta. This is
   the only first-party number you can get, and it is the same property you already use for text
   accounting.
2. Do not hardcode `4096`. Call `SystemLanguageModel.contextSize` — it is `@backDeployed(before: iOS
   26.4, macOS 26.4, visionOS 26.4)` and it varies by device tier.
3. Downscale aggressively yourself if you are near the budget. Apple says you *don't need to* crop
   or pad; it never says you shouldn't. Their own prompt-engineering advice is *"Consider whether
   preprocessing is necessary before passing an image to an on-device model, such as isolating a
   region of interest."*

> 🟡 **DEVICE-MEASURED FAILURE — `tokenCount(for:)` did not count attachments on this seed.** `SystemLanguageModel.tokenCount(for:)`
> shipped in **26.4** and Apple's C shim for the Python SDK exposes
> `FMSystemLanguageModelTokenCountForPrompt(model, FMComposedPrompt, …)` — and an `FMComposedPrompt`
> *can* carry attachments. So counting a prompt that contains an image is at least *expressible*.
> On an iPhone 15 Pro running iOS build `24A5408d`, the text-only prompt returned 6 tokens, while
> the same prompt with each of six images from 128 to 1,792 px threw
> `FoundationModels.LanguageModelError` code `-1` (`Unable to tokenize prompt` in the device log).
> Ordinary `respond` calls accepted the same generated image, so this is a counting-path limitation,
> not proof that image prompting is unavailable. Do not build a multimodal context meter on this
> method in the tested beta. The actual per-image cost remains unknown.

Cross-reference: the whole context-budget discipline, including the 26 vs 27 compaction idioms,
lives in [Part 3 · context window and KV cache](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md).

### 4.3 Latency

There is no published latency figure for image input either — not from Apple, not from the
community. What *is* documented is that the OS throttles on-device inference by system conditions:

> ✅ **VERIFIED** (Apple Frameworks Engineer, forum thread 833666): *"The OS manages the requests for
> the on-device LLM automatically, based on the system conditions (like thermals). **There's no
> entitlement or API to influence this.**"*

So a burst of large images in a background task is exactly the workload most likely to be delayed or
cancelled, and there is no priority knob. Design the UI for it.

---

## 5. Orientation is your problem

This section is longer than it looks like it should be, because orientation is where correct-looking
code produces confidently wrong answers with no error anywhere.

### 5.1 The parameter

Both initializers take an `orientation:`. Apple's own comment tells you when:

```swift prelude:guide-context
// When the image doesn't have a rotation applied, like when you get a
// image from the `AVFoundation` framework, use orientation to perform
// a transform before sending it to the model.
Attachment(imageTwo, orientation: .right)
```

`.right` is the only case name attested at an Apple call site in the corpus, and the type is no
longer inferred:

> ✅ **VERIFIED (2026-07-29) — the orientation type is `CGImagePropertyOrientation`, optional,
> defaulting to `nil`.** Every `Attachment` image init is declared `orientation:
> ImageIO.CGImagePropertyOrientation? = nil` — ✅ **SDK-verified**
> (`FoundationModels-27.0-macos.swiftinterface:2856-2860`), and the same signature appears on all
> four `Transcript.ImageAttachment` inits (`:2410-2413`), whose stored property is a non-optional
> `var orientation: CGImagePropertyOrientation { get }` (`:2407-2409`). So the standard
> EXIF-orientation enum it is; `nil` means "the framework was told nothing."

There is one conspicuous thing about the parameter: **Apple's own shipping multimodal sample never
uses it.** Origami attaches `UIImage(data:)` / `NSImage(data:)` values and calls
`Attachment(image).label(idString)` with no `orientation:` argument anywhere in the project. That is
a defensible choice on Apple's part — `UIImage(data:)` reads EXIF into `imageOrientation`, so the
orientation is already inside the value being attached, unlike a bare `CGImage`, which carries none.

> 🔴 **GAP — does the framework read `UIImage.imageOrientation`?** The sample's behaviour is
> consistent with the framework honouring the container type's own orientation, and consistent with
> the sample simply having no rotated test photos. Nothing in the corpus states which. **If you
> attach `UIImage`/`NSImage`, do not assume the orientation travels with it** — the cheap insurance
> is to normalise at your app boundary anyway (§5.3). Resolve by attaching the same JPEG twice on a
> 27.0 device — once as a `UIImage` with `imageOrientation == .right`, once as its bare `.cgImage` —
> and comparing the two descriptions.

### 5.2 Why this bites

A `CGImage` has no orientation. Orientation lives in container metadata (EXIF), and whether it gets
applied depends entirely on **which loader you used**. That is not a Foundation Models quirk; it is a
CoreGraphics fact. But the consequences here are unusually bad, because the model will happily
describe a sideways photo as a sideways scene and tell you so in fluent prose.

The clearest evidence that this is a real, pervasive, unsolved problem in Apple's own code is what
Apple ships in the *non-LLM* half of `apple/coreai-models` — the vision products you would reach for
when Foundation Models isn't enough:

> ✅ **VERIFIED** — from a full read of `swift/Sources/` in `apple/coreai-models`:
> - **`CVPixelBuffer` appears zero times in the entire non-LLM Swift tree.** Every vision product
>   takes a `CGImage` (or a `URL`/`CIImage` it immediately converts to `CGImage`) and hand-builds a
>   Float32 `NDArray`. There is no `CVPixelBuffer`-backed zero-copy path in that repo.
> - **There is no orientation handling anywhere in `ImagePreprocessor`.** And the two entry points
>   disagree: `CIImage(contentsOf:)` *does* apply EXIF orientation, while
>   `CGImageSourceCreateImageAtIndex` — the loader used by the repo's own CLI tools — *does not*.
>   *"So the same JPEG can be preprocessed two different ways depending on which entry point you
>   use. This is a real, unfixed inconsistency in the repo."*

Read that twice. In Apple's own shipping vision sample code, **the same file gives you two different
tensors depending on which two-line loader you picked**, and nothing warns you. Foundation Models'
`orientation:` parameter exists precisely because the framework cannot know what your loader did.

> ⚠️ **SILENT FAILURE — the rotated photo.** Attach a portrait photo from an iPhone camera roll that
> carries EXIF orientation 6, loaded via `CGImageSourceCreateImageAtIndex` without applying that
> orientation, and you get a sideways image. The model does not throw. It does not warn. It produces
> a perfectly fluent, perfectly wrong answer: it will call a standing person "lying down", read
> rotated text as gibberish, and describe a landscape as a portrait. The only symptom is quality —
> which is exactly the symptom developers attribute to "the model isn't very good yet". If your
> image-understanding feature is mysteriously worse on camera-roll photos than on screenshots,
> **this is why**: screenshots have no EXIF rotation and camera photos do.

### 5.3 The rule

**Normalise orientation exactly once, at your app's boundary, and know which convention you chose.**
Two defensible policies:

- **Bake it into the pixels.** Rotate on load so the `CGImage` is already upright, then never pass
  `orientation:`. Simplest to reason about; costs a redraw.
- **Carry it.** Keep the raw `CGImage` plus its `CGImagePropertyOrientation` together in one value
  and always pass both. This is what the forum poster in thread 838613 did:
  ```swift prelude:guide-context
  Attachment(modelImage.cgImage, orientation: modelImage.orientation)
  ```

What you must not do is mix them — some paths baking, some carrying — because the two compose into a
double rotation, and a double rotation is not obviously wrong to a human reviewer looking at
`response.content`.

If you take images from `PhotosPicker`, from a share extension, from `AVCapturePhotoOutput`, and
from drag-and-drop, that is **four** loaders with four orientation behaviours. Write one function.

---

## 6. Labels and `ImageReference`: keying output back to inputs

This is the highest-value pattern in the whole multimodal surface, and no WWDC session covers it. It
only exists in Apple's Origami sample and on the `ImageReference` symbol page.

### 6.1 The problem

You attach five photos and ask for structured analysis. The model returns five `ImageAnalysis`
values. **Which one is about which photo?** Positional matching is a guess — the model may reorder,
merge or skip. Prose references ("the third image") are unparseable.

### 6.2 The mechanism, end to end

Four stages, all four of them verified against Apple's Origami sample. This is the complete
round-trip: app object → labelled attachment → structured output → back to the same app object.

**Stage 1 — mint a stable label on your app's own model object.**

```swift prelude:guide-context
// Origami/Models/DataModels/Photo.swift:65-67 — Apple sample source
var idString: String {
    "Photo_\(id.uuidString.prefix(6))"
}
```

The label is derived from the object's identity, not from its filename, not from its index in an
array, and not from anything the user typed. It is stable across sessions and across app launches,
which is what makes step 4 work after a relaunch.

**Stage 2 — attach, labelled, and return a `Prompt` per image.**

```swift prelude:guide-context
// Origami/Models/DataModels/Photo.swift:77-91 — Apple sample source, verbatim
func toPrompt() async throws -> Prompt {
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else {
        return Prompt {}
    }
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else {
        return Prompt {}
    }
    #endif
    let idImage = Attachment(image).label(idString)
    return Prompt {
        idImage
    }
}
```

Then splice the `[Prompt]` into the real prompt (§3.2's `Orchestrator.swift:596-616` snippet). N
images, N labels, one call.

**Stage 3 — declare the `ImageReference` field in the `@Generable` type.**

```swift compile:27 imports:FoundationModels
// Origami/Brainstorm/ImageAnalysis.swift:11-27 — Apple sample source, verbatim
@Generable
struct ImageAnalysis {
    var image: ImageReference
    var analysis: String

    @Guide(
        description:
            "What do you think the *purpose* of this photo is for the project?"
    )
    var typeOfImage: ImageCategory
}

@Generable
enum ImageCategory: String, Codable {
    case craftInspiration = "inspiration for the craft"
    // …
}
```

Two things are doing work here. `var image: ImageReference` is an ordinary stored property of a
`@Generable` struct — there is no attribute, no `@Guide`, no registration step; `ImageReference`
conforms to `Generable` and that is the entire integration. And `ImageCategory`'s **sentence-length
raw value** is the prompt-facing description of the case, so the enum needs no `@Guide` at all.

**Stage 4 — resolve the label back to your object.**

```swift prelude:guide-context
// Origami/Brainstorm/BrainstormModel.swift:142-144 — Apple sample source, verbatim
let photo = project.photos.first { photo in
    photo.idString == image.attachmentLabel
}
```

That closes the loop: the same `idString` that went out as the attachment's label comes back as
`attachmentLabel`, and `first(where:)` over your own collection is the whole lookup. Note that the
sample does **not** call `ImageReference.resolved(in:)` here — it does not want the pixels back, it
wants the `Photo` object with its SwiftData relationships. `resolved(in:)` is for the other case
(§6.3), where a tool needs the image itself.

**And it works while streaming.** The sample reads the reference out of a partial snapshot before the
analysis prose has finished generating:

```swift illustrative
// Origami/Brainstorm/BrainstormModel.swift:168-171 — verbatim
for item in partialResponse.content.images ?? [] {
    // Need at least an ID to start streaming.
    if let id = item.image?.attachmentLabel {
```

That is the whole trick: because `attachmentLabel` is a short string emitted early in the structured
output, your UI can bind a result card to the right thumbnail before the prose arrives. Note the
double Optional — in a partial snapshot **every** field is Optional, so it is
`partialResponse.content.images` (`[ImageAnalysis.PartiallyGenerated]?`) and then `item.image`
(`ImageReference?`).

> 🟡 **RECONSTRUCTED — the container type.** `partialResponse.content.images` proves the top-level
> `@Generable` type has an `images` array of `ImageAnalysis`, but the sample notes do not quote that
> type's declaration. Write it the obvious way (`@Generable struct BrainstormAnalysis { var images:
> [ImageAnalysis] }`) and let Xcode confirm; everything else in this section is verbatim.

Origami also pairs this with the reveal-N−1 polish trick — hold the in-progress item back so its
text does not visibly grow mid-stream (`BrainstormModel.swift:120-123`).

> ⚠️ **SILENT FAILURE — a stream that yields zero partials.** A `ResponseStream` can complete having
> yielded **no** partial at all, when the model's only output for that turn was a tool call. Apple
> handles this explicitly (`Origami/Coach/CoachModel.swift:58-73`: `var didReceivePartial = false`,
> and if it is still `false` after the loop, land on `.responded("")`). Multimodal turns are
> disproportionately exposed to this, because attaching an image is exactly when you also hand the
> session an `OCRTool`, a `BarcodeReaderTool` or your own photo tool. **Any "spinner until the first
> token" UI hangs forever on that turn** — and it hangs after a *successful* call, so there is no
> error to catch and nothing in the log. Track whether you ever received a partial, and exit the
> loading state on stream completion regardless. Full treatment in
> [guided generation and streaming](02-guided-generation-and-streaming.md).

See that same guide for how partial snapshots work generally.

### 6.3 `ImageReference` in tool arguments

`ImageReference` conforms to `Generable`, so it is also legal as a tool argument — which is how you
let the model hand an image *back* to your code for real processing. Apple's documented pattern:

```swift illustrative
// /documentation/foundationmodels/imagereference — Apple's snippet, verbatim
struct MyTool: Tool {
  @SessionProperty(\.history) var history

  @Generable
  struct Arguments {
    var image: ImageReference
  }

  public func call(arguments: Arguments) async throws -> Output {
    guard let imageAttachment = arguments.image.resolved(in: history) else {
      throw ImageToolError.imageNotFound(arguments.image.attachmentLabel)
    }
    let image = imageAttachment.cgImage
    ...
  }
}
```

> ✅ **VERIFIED** — *"Use `ImageReference` to allow the model to reference images from the current
> `LanguageModelSession`'s transcript."* `resolved(in:)` returns `Transcript.ImageAttachment?`.

The older, **deprecated** form takes a `Transcript` rather than the history slice, and Apple's own
article still shows it:

```swift prelude:guide-context
// Deprecated form, from the same article — kept here because you will meet it in older code
func call(arguments: Arguments) async throws -> String {
    // Get the image attachment from the session history.
    guard let attachment = arguments.image.resolve(in: Transcript(entries: sessionHistory)) else {
        return "The image isn't in the session history."
    }

    // Perform a classification request on the image to get the top five
    // observations.
    let observations = try await ClassifyImageRequest().perform(on: attachment.ciImage)
    let top = observations.prefix(5)
    return top.map { $0.identifier }.joined(separator: ", ")
}
```

Note the type mismatch between the two: `resolved(in:)` takes a `some Sequence<Transcript.Entry>`
(beta 5 spelling, `27.0:3024-3027`; `Transcript.HistoryView`, which `@SessionProperty(\.history)`
vends, satisfies it) while
`resolve(in:)` takes a whole `Transcript`. That signature change is almost certainly the reason for
the deprecation. **Prefer `resolved(in:)` with `@SessionProperty(\.history)`.**

Also note what that deprecated snippet quietly demonstrates: **Apple's own documented example of what
to do with a referenced image is to hand it to the Vision framework** (`ClassifyImageRequest`). Hold
that thought until §9.

Two caveats on the recommended form, both worth knowing before you build on it:

- **No sample exercises it.** `@SessionProperty(\.history)` appears in none of the three 2026 Apple
  sample projects; the pattern above is documentation-sourced only. That is not a reason to avoid it,
  but it is a reason to expect the first compile to be educational.
- **You often don't need `ImageReference` in a tool at all.** Origami's photo tool — the one that
  moves a user-supplied photo to a tutorial step — takes *indices*, not an image:
  ```swift prelude:guide-context
  // Origami/Coach/MovePhotoToStepTool.swift:12-38 — Apple sample source
  struct MovePhotoToStepTool: Tool {
      let name = "movePhotoToStep"
      let description = "Move a photo the user gave you to the correct step of a tutorial."
      var orchestrator: Orchestrator            // the tool holds the app's @Observable model

      @Generable
      struct Arguments: Sendable {
          @Guide(description: "Section to move the photo TO")
          var tutorialSectionIndex: Int
          @Guide(description: "Step to move the photo TO")
          var tutorialStepNumber: Int
      }
  }
  ```
  The app already knows which photo is in play, so the model is only asked for the *destination*. Use
  `ImageReference` when the model must pick **which** image out of several; use plain arguments when
  the ambiguity is somewhere else. (That tool's return value is also a nice pattern in its own
  right — it returns *"Asked the user to confirm moving to step N."*, i.e. a tool call used as a
  request for consent rather than a computation. See
  [tools and tool calling](03-tools-and-tool-calling.md).)

### 6.4 Labelling rules

- **Stable and unique.** Apple's advice: *"Assign stable labels across sessions to enable
  `ImageReference` linking in structured outputs."*
- **App-generated, not user-facing.** Origami uses `"Photo_" + first six characters of a UUID`. Do
  not use the filename — two photos named `IMG_1234.jpg` will collide.
- **Short.** The label is text in the prompt; it costs tokens on every turn it survives in the
  transcript.
- **Mandatory when an image must be referenced by identity.** Apple: *"Labels help the model identify
  specific attachments when making tool calls."* Apple's `BarcodeReaderTool` example labels its
  input `"barcode-image"`, and an `ImageReference` cannot resolve a specific attachment without a
  stable handle. See the measured boundary immediately below.

> ⚠️ **SILENT FAILURE — the missing identity handle.** For a text prompt or a generic tool call, a
> label is optional. For structured output or a tool argument that must name a particular image,
> `.label(_:)` supplies the handle returned by `ImageReference.attachmentLabel` and consumed by
> `resolved(in:)`; an absent or hallucinated handle makes lookup return `nil`.
>
> **Runtime boundary, updated 2026-09-16:** on stable macOS 27 (`26A428`) and iPhone 15 Pro /
> iOS 27 build `24A435`, ordinary labeled and unlabeled image responses succeeded and transcript
> write-through remained exact: `label:nil` versus `.label("probe-img")`. In both destinations a
> required generic `EchoTool` reached `toolRan=true` but the enclosing turn timed out. That matches
> the 2026-08-20 beta-5 device run; it is a reverified limitation, not runtime drift. It does not
> make labels the cause: both labeled and unlabeled cases behave alike. The probes did not exercise `BarcodeReaderTool`,
> `OCRTool`, or an `ImageReference` argument, so keep labels mandatory for those identity-dependent
> paths and regression-test the specific built-in tool you ship.
>
> ```swift
> // ✅ correct
> let session = LanguageModelSession(tools: [BarcodeReaderTool()])
> try await session.respond {
>     "Scan this image for any barcodes and explain the encoded content."
>     Attachment(image).label("barcode-image")     // ← REQUIRED, not decoration
> }
>
> // ⚠️ ambiguous — a generic tool may run, but no stable image identity is recorded
> try await session.respond {
>     "Scan this image for any barcodes and explain the encoded content."
>     Attachment(image)                            // ← no label
> }
> ```
>
> The rule for the file-URL path is the same and the ergonomics are worse, because `.label(_:)` there
> is a rebinding rather than a chained call (§3.3): `var a = Attachment(imageURL: url); a =
> a.label(id)`. Easy to write the first line and forget the second. **If a tool or structured result
> may refer to an image, label every attachment in that request.**

> ⚠️ **SILENT FAILURE — the unmatched label.** `resolved(in:)` returns an *Optional*, and the
> Origami sample's lookup is `first { $0.idString == image.attachmentLabel }` — also Optional. The
> model can hallucinate a label that was never attached, or return one from a turn you have since
> compacted out of the transcript. Neither case throws: you get `nil`, and if you wrote
> `if let photo = …` with no `else`, the result silently vanishes from your UI. **Always handle the
> `nil` branch, and log it** — a rising rate of unmatched labels is your early warning that history
> compaction is eating your attachments (§7.3).

---

## 7. The transcript side: `AttachmentSegment`, `ImageAttachment`, and the cost of remembering

An image you attach does not evaporate after the response. It becomes part of the session transcript,
where it is visible to you, re-sent to the model on subsequent turns, and — if you are writing a
custom `LanguageModel` provider — something you have to serialize.

### 7.1 The types

```swift illustrative
// Transcript.AttachmentSegment                       iOS 27.0+ Beta
init(id:content:label:)
var content
var label

// Transcript.Attachment  — one-case enum today
public enum Attachment: Sendable, Equatable {
  case image(ImageAttachment)
}

// Transcript.ImageAttachment                          iOS 27.0+ Beta, Equatable + Sendable
init(_:orientation:)
init(imageURL:orientation:)
var cgImage
var ciImage
var orientation                             // "The display orientation of the image."
var url                                     // "The URL of the original image asset, if the
                                            //  attachment was created from a URL."
func pixelBuffer(resolution:pixelFormat:)   // "Returns the image as a ..., optionally resampled
                                            //  to a given resolution and pixel format."
```

> ✅ **VERIFIED** — `/documentation/foundationmodels/transcript/imageattachment` and
> `/documentation/foundationmodels/transcript/attachmentsegment`. The `Attachment` enum shape comes
> from Apple's own `SKILL.md` at `skills/foundation-models-language-model-protocol/SKILL.md:455-463`
> in `github.com/apple/foundation-models-utilities`, which also states that `ImageAttachment` is
> buildable from *"a `CGImage`, `CIImage`, `CVPixelBuffer`, or a `URL`"*.

`Transcript.ImageAttachment` is the *read* side of what `Attachment` writes. It is what
`ImageReference.resolved(in:)` hands you, and it is genuinely useful: `.cgImage` and `.ciImage` give
you the pixels back in either framework's currency, and `pixelBuffer(resolution:pixelFormat:)` will
resample for you — which is the one place in this whole surface where the framework offers to do
image resizing on your behalf, and it is on the *output* side.

### 7.2 `url` became Optional — a real beta-to-beta source break

> ✅ **VERIFIED by diff.** `Transcript.ImageAttachment.url` was **non-Optional in beta 1** and
> **Optional in beta 3**. The evidence is Apple's own code in `foundation-models-utilities`: the
> beta-1 `ChatCompletionsLanguageModel` reads `image.url.scheme` directly; the beta-3 revision of the
> same file opens with `guard let url = image.url else { throw … }`. (Repo
> `github.com/apple/foundation-models-utilities`, `Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift:423`,
> commit `376ca60e61985369d5067bd3c575bdb6a13f0e1b`.)

The semantics that change with it are the interesting part. Optional `url` means: **an attachment
created from an in-memory image has no URL.** Only attachments created via
`Attachment(imageURL:orientation:)` carry one, exactly as the doc comment now says — *"The URL of
the original image asset, **if the attachment was created from a URL**."*

If you wrote beta-1 code that reached for `attachment.url` to re-open the original file, that code
now needs a fallback path through `.cgImage`. And if you are writing a custom provider, this is the
distinction that determines whether your provider works at all on non-Apple platforms — §10.2.

### 7.3 Images accumulate, and they are not free to keep

Three separate facts compound here.

**(a) Every attachment stays in the transcript.** The `Transcript.Prompt` entry carries segments, and
`.attachment` is now one of the segment cases. Apple's own description of `Transcript.Entry.prompt`
is *"user message (may contain text + images)"*.

**(b) Re-sending is the default.** On every subsequent turn the whole transcript is the model's
context. Five images attached over five turns are five images in context on turn six — inside a
4,096-token on-device window.

**(c) Attachments add; they never replace.** From Apple's provider `SKILL.md` pitfall list, verbatim
headline: *"Attachments add, they don't replace."* And: *"There is **no** `replaceAttachmentSegment`"*
— the channel API offers `.addAttachmentSegment(_:)` and `.removeAttachmentSegment(_:)` only, so
"replace" is remove-then-add.

The practical consequence is that a long multimodal conversation will hit `contextSizeExceeded`
faster than a text one, and your compaction strategy has to have an opinion about images. But the
standard compaction tool has a sharp edge:

> ⚠️ **SILENT FAILURE — `summarizeHistory` flattens your images away.** Apple's own
> `summarizeHistory` modifier *"will condense all entries into a `.prompt` entry"* (Frameworks
> Engineer, forum thread 833706), and Apple's designer added that it *"currently doesn't support
> preserving metadata like tool call IDs."* Nothing in the corpus says attachment segments survive
> summarization — and a text summary of a conversation, by construction, does not contain pixels.
> After a summarization pass, `ImageReference.resolved(in:)` for an older image will start returning
> `nil` (§6.4) and the model will begin answering questions about images it can no longer see,
> **from its own earlier text description of them**, with no error and no visible transition. If
> image fidelity matters across long conversations, write your own `DynamicProfileModifier` with
> `historyTransform` that preserves `.attachment` segments, and hold the originals in your app model
> so you can re-attach. See [dynamic profiles and session state](../../part-03-context-profiles-agentic/references/02-dynamic-profiles-and-session-state.md).

### 7.4 The migration footgun

`Transcript.Segment` gained `.attachment` and `Transcript.Entry` gained `.reasoning` in iOS 27.

> ⚠️ Any **exhaustive `switch`** over `Transcript.Entry` or `Transcript.Segment` written against the
> iOS 26 SDK **fails to compile** against the iOS 27 SDK. That is the good outcome — it is a
> compile-time break, not a runtime one. The bad outcome is the code that already had a `default:`
> clause, which will now silently route image segments into "unknown, ignore". If you render
> transcripts in your UI (a chat history view, a debug inspector), audit every `default:` over these
> two enums before you ship on 27.

Here is Apple's canonical transcript-rendering switch, from the `Transcript` documentation page —
note that it covers `Entry`, so it does *not* itself show the `.attachment` **segment** case:

```swift prelude:guide-context
struct HistoryView: View {
    let session: LanguageModelSession

    var body: some View {
        ScrollView {
            ForEach(session.transcript) { entry in
                switch entry {
                case let .instructions(instructions):
                    MyInstructionsView(instructions)
                case let .prompt(prompt):
                    MyPromptView(prompt)
                case let .reasoning(reasoning):
                    MyReasoningView(reasoning)
                case let .toolCalls(toolCalls):
                    MyToolCallsView(toolCalls)
                case let .toolOutput(toolOutput):
                    MyToolOutputView(toolOutput)
                case let .response(response):
                    MyResponseView(response)
                }
            }
        }
    }
}
```

Inside `MyPromptView`, you now need a second switch over `prompt.segments` that handles
`.text`, `.structure`, `.attachment(let attachment)` and `.custom`, with `@unknown default`.

---

## 8. Structured output from images, and the two Vision-backed tools

### 8.1 Classification with greedy sampling

Apple's documented classification recipe pairs a `@Generable` enum with deterministic sampling:

```swift compile:27 imports:FoundationModels,CoreGraphics
@Generable
enum ImageLabel {
    case cat
    case dog
    case frog
    case bird
}

func classifyImage(_ image: CGImage) async throws -> ImageLabel {
    let session = LanguageModelSession()
    let response = try await session.respond(
        generating: ImageLabel.self,
        options: GenerationOptions(samplingMode: .greedy)
    ) {
        "Choose the label that best represents the following image:"

        Attachment(image)
    }
    return response.content
}
```

> ✅ **VERIFIED** — Apple's snippet from the multimodal-prompting article, plus its TIP: *"Use the
> `greedy` sampling option when you want the model to always pick the most likely option; otherwise,
> the model may select an option that's close."*

> ⚠️ **API-spelling conflict, unresolved.** Apple's article writes the initializer label as
> `GenerationOptions(samplingMode: .greedy)`. Every other source in the corpus — Apple's own 2025
> Foundation Models code-along, a shipping third-party app compiled against the 27 SDK
> (`GenerationOptions(sampling: sampling, temperature:…, maximumResponseTokens:)`), and the Python
> SDK's mirror of the type — writes the *initializer label* as `sampling:` while the *property* and
> the profile modifier are named `samplingMode`. Both spellings may exist (a 27.0 overload alongside
> the 26.0 one); the corpus contains no header to adjudicate. **Let Xcode complete it**, and do not
> copy either spelling into a code-generation prompt without checking. Tracked in §12.

Two things about greedy sampling and images specifically. First, it is the difference between a
classifier you can write tests for and one you cannot — see
[Part 6 · Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md), since there is no model-version pinning
API and OS updates change the model underneath you. Second, `@Generable` enums with
sentence-length raw values are a documented Apple trick — Origami's `ImageCategory` uses
`case craftInspiration = "inspiration for the craft"`, so the raw string doubles as the
prompt-facing description of the category (✅ `Origami/Brainstorm/ImageAnalysis.swift:23-27`).

### 8.2 Apple's prompt-engineering guidance for images

Verbatim, from the multimodal article:

> - *Describe clearly what you want the model to analyze or extract. Instead of asking, "What's in
>   this image?," try "List all food items in this photo."*
> - *Consider whether preprocessing is necessary before passing an image to an on-device model, such
>   as isolating a region of interest.*
> - *Use the `Generable` protocol to constrain responses to specific formats.*

The middle bullet is the one people skip. "Isolating a region of interest" means: if you already know
*where* to look — because Vision told you, or because the user tapped — **crop before you attach**.
You get a smaller image (cheaper, faster) and a model that isn't distracted. This is also the honest
workaround for §9's limitation: the model is good at describing what is in a crop, and bad at telling
you where to crop.

### 8.3 `OCRTool` and `BarcodeReaderTool`

Two `Tool` implementations provided by the Vision framework, new in 27.0:

> ✅ **VERIFIED** — *"The Vision framework provides optical character recognition (OCR) and barcode
> tools that you can add to a session in the Foundation Models framework. Use `BarcodeReaderTool` to
> detect barcodes and interpret their encoded content, and `OCRTool` to extract text from images."*
> WWDC26 241 adds the rationale: *"Both enhance a model's ability to reason about visual information
> **in ways it can't natively**."*

```swift compile:27 imports:FoundationModels,Vision
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

Note the label on the attachment — that is the stable handle by which a tool can identify the image.
A generic-tool device probe showed that an unlabeled attachment does not universally suppress tool
invocation; the built-in Vision-tool path still needs a direct A/B (§6.4). "In ways it can't
natively" is Apple telling you, in the politest possible terms, that the model's own OCR of a
dense document is not to be trusted and its barcode decoding does not exist. Both tools live in the
**Vision** framework's documentation, not Foundation Models'. Deeper coverage of the built-in tools
is in [Spotlight RAG and system tools](04-spotlight-rag-and-system-tools.md).

> ✅ **RESOLVED (2026-07-29) — the tools' own API surface, from the cross-import overlay.** The
> parent `Vision.swiftinterface` was empty of them because they were never there: both tools live
> in **`_Vision_FoundationModels`**, the overlay module the compiler activates only when a file
> imports **both** `Vision` and `FoundationModels`
> (✅ **SDK-verified**, `notes/sdk-interfaces/_Vision_FoundationModels-27.0-macos.swiftinterface:14-47`
> `BarcodeReaderTool`, `:49-83` `OCRTool`). The surface is minimal:
> `init(name: String? = nil, description: String? = nil)` is the whole configuration — **no
> symbology or language knobs exist**; `Arguments` is a real nested `Generable` struct whose
> model-facing fields are not emitted in the interface (the schema surfaces at runtime via
> `generationSchema`); and the output is an **opaque** `some PromptRepresentable` — you cannot name
> the type, only compose it into prompts. `BarcodeReaderTool` is additionally watchOS 27.0;
> `OCRTool` is watchOS-unavailable; both are tvOS-unavailable. Failure modes remain unknown, and
> **neither type appears in any of Apple's three 2026 sample projects** — the snippet above is
> still the whole of the published call-site evidence.

---

## 9. What the model cannot do with pixels

Everything above is the happy path. This section is the one that will save you a sprint.

### 9.1 The finding

**The on-device model reliably lists what is in an image. It does not reliably tell you where.**

The primary evidence is Developer Forums thread **838613**, *"Foundation Models, image input and
locating things within an image"* (jaywardell, 20 July 2026), which is the only systematic public
investigation of this behaviour in the corpus. The reporter's summary: image identification works
well, and the model *"consistently lists the items in the image and gives me bounding boxes"* — the
boxes are the problem, not the enumeration.

They tried four coordinate conventions, and reported on each:

| Convention tried | Result reported |
|---|---|
| Raw pixel coordinates | *"almost usable but often off by 1–2× the object width/height, or cluster rectangles at the top of the image"* |
| Normalized 0…1 | unreliable |
| Integer percent 0…100 | unreliable |
| "Soft location" descriptors ("upper left", "centre") | *"most consistent but incomplete"* |

They even primed the model with the exact frame of reference, which is the right thing to try:

```swift prelude:guide-context
// Forum thread 838613 — the prompt that still didn't produce reliable boxes
let prompt = Prompt {
    "Describe this \(imageWidth)×\(imageHeight) image. Bounding box coordinates are in pixels: (0,0) is top-left, (\(imageWidth),\(imageHeight)) is bottom-right."
    Attachment(modelImage.cgImage, orientation: modelImage.orientation)
}
```

Note the failure signature in the first row: *"cluster rectangles at the top of the image."* That is
the classic look of a language model emitting plausible-looking numbers rather than measuring
anything — the coordinates are generated text, not a regression head's output. There is no bounding
box inside the model to read out.

### 9.2 Apple's answer

> ✅ **VERIFIED** — Apple Designer (Apple), thread 838613, marked *Recommended*, verbatim:
>
> *"Really great feedback, thanks! We'll get this to the Vision framework + FoundationModels
> engineers.*
>
> *In the meantime, the Vision framework is the modern Swift successor to VisionKit that has a bunch
> of saliency and classification APIs that may be helpful."*

Two readings of that, both correct:

- **It is a redirect, not a fix.** "In the meantime … the Vision framework" is Apple telling you that
  spatial localisation is not what this model is for, today. There is no radar number, no "we'll fix
  it in a later beta", no documented roadmap.
- **It is consistent with Apple's own documentation.** Remember §6.3: Apple's own `ImageReference`
  tool example resolves an image out of the transcript and immediately hands it to
  `ClassifyImageRequest()` from Vision. Apple's own sample code treats the model as a *router* to
  vision APIs, not as a vision API.

The pattern generalises across the whole 2026 surface. `OCRTool` and `BarcodeReaderTool` exist —
Vision-backed, in the framework — precisely because the model *"can't natively"* do those things
either. Text extraction: Vision. Barcodes: Vision. Localisation: Vision. Semantic description of
what a thing *is*: the model.

**And it is what Apple's own sample code does.** Origami is the only 2026 Apple sample that attaches
images, it attaches many of them at once, and every question it asks about them is *semantic*: free
prose in `analysis`, and a category chosen from a `@Generable` enum in `typeOfImage` — *"What do you
think the **purpose** of this photo is for the project?"* There is **no coordinate, no bounding box,
no region and no measurement anywhere in the sample's multimodal surface**, and no `Int`- or
`Double`-typed spatial field in `ImageAnalysis`. When Apple ships a multi-image feature, it asks the
model what the pictures *mean* and never asks it where anything is. Take the hint.

### 9.3 Use the right tool — the decision table

| You want… | Use | Why |
|---|---|---|
| "What is in this photo?" / a caption / a category | **Foundation Models** + `@Generable` enum + greedy sampling | This is exactly what it is good at (§8.1) |
| "Is this receipt, invoice or business card?" | **Foundation Models**, classify into a `@Generable` enum | Semantic, not spatial |
| "Read the text on this label" | **`OCRTool`** (Vision) via a session, or Vision directly | Apple: the model can't do this natively |
| "Decode this barcode" | **`BarcodeReaderTool`** (Vision) | Same |
| "Where is the dog in this photo?" (a box) | **Vision**, or a detection model via Core AI | The model's coordinates are generated text |
| "Which pixels belong to the dog?" (a mask) | **Segmentation model via Core AI** (SAM 3 / EfficientSAM) | No FM surface for masks at all |
| "Crop to the interesting part" | **Vision saliency** | Apple's own recommendation in thread 838613 |
| "Describe *this region*" | **Vision to find it → crop → Foundation Models to describe it** | Apple's documented advice: *"isolating a region of interest"* |

That last row is the composite pattern and the one worth internalising: **localise with a real vision
model, then describe with the language model.** You crop before you attach, which is cheaper in
tokens, faster, and dramatically more accurate than asking one model to do both jobs.

> ✅ **RESOLVED (2026-07-29) — the modern Swift Vision request names, read from the captured macOS
> 27.0 Vision interface** (`notes/sdk-interfaces/Vision-27.0-macos.swiftinterface`; all are
> `public struct … : ImageProcessingRequest`). The ones this guide's decision table needs:
>
> | Job | Request type | Citation |
> |---|---|---|
> | Classification | `ClassifyImageRequest` | `Vision-27.0-macos.swiftinterface:2556` |
> | Text recognition (OCR) | `RecognizeTextRequest` | `:2591` |
> | Document structure + text | `RecognizeDocumentsRequest` | `:2409` |
> | Barcodes | `DetectBarcodesRequest` (result `[BarcodeObservation]`, `symbologies:` knob) | `:940-966` |
> | Saliency (attention) | `GenerateAttentionBasedSaliencyImageRequest` | `:340` |
> | Saliency (objectness) | `GenerateObjectnessBasedSaliencyImageRequest` | `:95` |
> | Rectangle detection | `DetectRectanglesRequest` | `:2522` |
> | Foreground/person masks | `GenerateForegroundInstanceMaskRequest` / `GeneratePersonInstanceMaskRequest` | `:1977`, `:1934` |
> | Your own Core ML model | `CoreMLRequest` | `:1646` |
>
> There is no general-purpose "detect arbitrary objects" request in the interface (animals, faces,
> humans, text and rectangles are the built-in detectors — `RecognizeAnimalsRequest:876`,
> `DetectFaceRectanglesRequest:3014`, `DetectHumanRectanglesRequest:1744`) — which is exactly why
> §9.4's Core AI route exists for custom detection. A dedicated Vision guide still does not exist
> in this series.

### 9.4 The Core AI route: real detection and real segmentation

When Vision's built-in requests don't cover your domain — you need to find *your* product on a shelf,
not "a dog" — you ship your own model through Core AI. `apple/coreai-models` ships two Swift products
for exactly this, with export recipes for well-known checkpoints.

> ✅ **VERIFIED** — `Package.swift` in `github.com/apple/coreai-models` declares these as products,
> with these targets and CLI tools:
>
> | Product | Module | Executable | Model recipes in `models/` |
> |---|---|---|---|
> | `CoreAIObjectDetection` | `CoreAIObjectDetector` | `object-detector` | **YOLOS** (`hustvl/yolos-base`, 127M; `-tiny`, 6.5M) |
> | `CoreAISegmentation` | `CoreAIImageSegmenter` | `image-segmenter` | **SAM 3** (`facebook/sam3`, 848M, gated) and **EfficientSAM** (10M) |

Note the module/product name mismatch in both rows — you write `import CoreAIObjectDetector` but add
`CoreAIObjectDetection` to your target's dependencies. That trips everyone once.

`CoreAIObjectDetection` is the smallest complete "run a vision model on Apple silicon" example that
exists — three files, 633 lines, no third-party dependencies:

```swift prelude:external-module
// ✅ VERIFIED public API — ObjectDetector.swift:14-333, DetectionOutputs.swift:33-134
import CoreAIObjectDetector   // module name; product is CoreAIObjectDetection
import CoreGraphics
import ImageIO

let detector = try await ObjectDetector(resourcesAt: "~/models/yolos.aimodel")
try await detector.warmup()                       // 1 image, .default params

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// single image, defaults: threshold 0.3, top 100, COCO labels, ImageNet normalization
let objects: [DetectedObject] = try await detector.detect(image: loadCGImage(imageURL)!)
for o in objects {
    print("\(o.label) (\(o.labelIndex)) \(String(format: "%.3f", o.confidence)) \(o.boundingBox)")
    // boundingBox is TOP-LEFT origin pixel coordinates on ALL platforms.
}

// batched: ONE forward pass over N images, results in input order
let images = urls.compactMap(loadCGImage)
let batched: [[DetectedObject]] = try await detector.detect(images: images,
                                                            parameters: .default)
// Requires the model's batch dim to be -1 (dynamic) or exactly images.count.
```

```swift illustrative
public struct DetectedObject: Sendable {
    public let boundingBox: CGRect      // pixel coords, TOP-LEFT origin on every platform
    public let labelIndex: Int
    public let label: String
    public let confidence: Float        // [0,1]
}

public struct DetectionParameters: Sendable {
    public var threshold: Float                                  // default 0.3
    public var maxDetections: Int                                // default 100
    public var normalizationMeans: (CGFloat, CGFloat, CGFloat)   // ImageNet (0.485, 0.456, 0.406)
    public var normalizationStds:  (CGFloat, CGFloat, CGFloat)   // ImageNet (0.229, 0.224, 0.225)
    public var classLabels: [Int: String]                        // default ObjectDetectionLabels.coco
    public var inputHeight: Int                                  // default 800
    public var inputWidth:  Int                                  // default 800
    public static let `default`: DetectionParameters
}
```

*That* is what a real bounding box looks like: a `CGRect` in pixels with a documented origin, a class
index, and a calibrated confidence you can threshold. Compare it to a language model emitting four
integers in prose and the distinction stops being abstract.

Three traps carried over from the source, so you don't rediscover them:

- ⚠️ **The two products disagree about the Y origin.** `DetectedObject.boundingBox` is
  **always top-left origin, on every platform**. The segmenter's `Segment.box` is **flipped on
  macOS** — its `SegmentationPostprocessor.decodeSegment` has an explicit
  `#if os(macOS)` branch computing `y: (1.0 - y1) * imageHeight` *"because AppKit uses bottom-left
  origin."* Same code, same model, same image → a different `y` on Mac and iPhone. And the repo's own
  `SegmentationVisualization.renderPromptBoxes` demands top-left *"regardless of platform"*, so on
  macOS you must not feed `Segment.box` straight into it.
- ⚠️ **Two box encodings in one repo.** The detector decodes DETR-family `[cx, cy, w, h]` normalized;
  the segmenter emits XYXY normalized. Check which one your exported model produces.
- ⚠️ **No NMS in the detector.** DETR/YOLOS are set-prediction models so non-max suppression is
  unnecessary — which means this postprocessor is **wrong for anchor-based YOLO variants**. And
  `decode` returns `[]` on any shape mismatch rather than throwing, so a wrong model gives you
  "detected nothing", silently.

Everything about loading, specializing and running `.aimodel` bundles lives in
[Part 7 · Core AI: the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md); the export
recipes are in [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md).

> 🔴 **GAP — no published quality or latency numbers for any of these vision models.** A repo-wide
> search of `apple/coreai-models` found perplexity tables only for the *LLM* recipes. **There is no
> published mAP, mIoU, PSNR, WER or latency figure for YOLOS, SAM 3, EfficientSAM or any other
> non-LLM model in that repo.** If you need to justify "detection model vs. asking the LLM" with
> numbers, you must generate them yourself. Nothing in this corpus lets anyone quote a figure.

### 9.5 A worked "right tool" composition

The shape of the composite pattern, with the parts that are verified marked as such:

```swift illustrative
import FoundationModels
import CoreGraphics

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
func describeRegionOfInterest(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    locate: (CGImage) async throws -> CGRect?   // ← your detector: Vision, or Core AI (§9.4)
) async throws -> String {
    // 1. Localise with something that actually measures pixels.
    guard let box = try await locate(image),
          let crop = image.cropping(to: box) else {
        return "Nothing found."
    }

    // 2. Describe the crop with the language model. Smaller image, fewer tokens,
    //    and no coordinates asked of a model that cannot produce them.
    let session = LanguageModelSession()
    let response = try await session.respond {
        "In one sentence, describe the object shown."
        Attachment(crop, orientation: orientation)
    }
    return response.content
}
```

The `Attachment(crop, orientation:)` call is ✅ verified API. The `locate` closure is deliberately a
parameter, because §9.3's GAP means this guide will not put a specific Vision request name in your
build.

---

## 10. Which backends accept images

`LanguageModelSession` is backend-agnostic in 2026 — `SystemLanguageModel`,
`PrivateCloudComputeLanguageModel`, `CoreAILanguageModel`, `MLXLanguageModel`,
`ChatCompletionsLanguageModel` and third-party packages all conform to the `LanguageModel` protocol.
Image support is **not** uniform across them, and the framework has a formal mechanism for saying so.

### 10.1 The capability gate

```swift illustrative
protocol LanguageModel: Sendable {
    associatedtype Executor: LanguageModelExecutor where Self == Executor.Model
    var capabilities: LanguageModelCapabilities { get }   // .vision / .guidedGeneration
                                                          // .reasoning / .toolCalling
    var executorConfiguration: Executor.Configuration { get }
}
```

> ✅ **VERIFIED** — the four capability cases are attested across Apple's `CoreAILanguageModel`,
> `MLXLanguageModel` and Apple's provider `SKILL.md`. `.vision` is documented on the Apple symbol
> page as *"The capability to accept image inputs in prompts."*

Capabilities are **routing-relevant, not decorative**. Apple's own MLX adapter documents the
mechanism for the sibling `.reasoning` capability:

> *"Declaring `.reasoning` matters for request routing: the framework **only forwards a
> `reasoningLevel` to executors that declare `.reasoning`, and auto-rejects one otherwise (on the
> developer's behalf) before `respond` runs.**"*

The corresponding rejection for images is `LanguageModelError.unsupportedCapability`, whose payload
carries `capability: LanguageModelCapabilities.Capability` — so a provider that has not declared
`.vision` gives you a *typed, catchable* error naming the missing capability, rather than a bad
answer. That is the one place in this whole guide where the failure is loud. Handle it:

```swift prelude:guide-context
do {
    let response = try await session.respond { "Describe this:"; Attachment(image) }
} catch let error as LanguageModelError {
    if case .unsupportedCapability(let payload) = error {
        // payload.capability tells you which one. Fall back to a text-only prompt,
        // or to a different model.
    }
    throw error
}
```

The provider-side story — declaring capabilities, translating attachment segments, and the
`.addAttachmentSegment` / `.removeAttachmentSegment` channel actions — is
[authoring a LanguageModel provider](../../part-04-beyond-the-built-in-model/references/03-authoring-a-languagemodel-provider.md).

### 10.2 The platform asymmetry — in-memory images are Apple-only

This is the finding that will surprise anyone taking Apple's *"everywhere Swift runs, including Linux
servers"* pitch at face value.

`ChatCompletionsLanguageModel` (in `apple/foundation-models-utilities` — the package that turns
`mlx_lm.server`, Ollama, vLLM and LM Studio into Foundation Models backends) has **two entirely
different image paths**:

```swift illustrative
// Darwin: encode the in-memory image inline as a base64 JPEG data URL.
//   image.cgImage.jpegData().base64EncodedString()  →  "data:image/jpeg;base64,…"
//   ChatCompletionsLanguageModel.swift:413-421, guarded by #if canImport(CoreImage)
```

```swift prelude:guide-context
// Non-Darwin (Linux/Windows): there is no CoreImage, so there is no encoder.
// ChatCompletionsLanguageModel.swift:422-441 — verbatim
guard let url = image.url else {                                  // :423
  throw LanguageModelError.unsupportedTranscriptContent(
    LanguageModelError.UnsupportedTranscriptContent(
      unsupportedContent: [entry],
      debugDescription: "Image attachment without a URL is not supported by \(Self.self) on this platform."
    )
  )
}
let dataURL: URL
if url.scheme == "data" {
  dataURL = url
} else {
  let data = try Data(contentsOf: url)                            // :435
  let base64String = data.base64EncodedString()
  dataURL = URL(string: "data:image/jpeg;base64,\(base64String)")!
}
```

Read the consequence carefully:

- **On Apple platforms**, `Attachment(someCGImage)` works with a Chat-Completions backend. The
  utilities package JPEG-encodes it for you via `CGImageDestinationCreateWithData` + `UTType.jpeg`.
- **On Linux**, `Attachment(someCGImage)` **throws** `unsupportedTranscriptContent`. An attachment
  must carry a `url` — which, per §7.2, means it must have been created with
  `Attachment(imageURL:orientation:)`. This is exactly why `ImageAttachment.url` became Optional: the
  Linux branch has to test for its absence.

So the portable idiom for shared Swift code is **file-URL attachments**, not in-memory images. If you
have pixels and no file, you write them to a temporary file (or synthesise a `data:` URL — the Linux
branch explicitly passes `data:` scheme URLs straight through).

Two further caveats about that Linux claim, from a full read of the repository:

> ⚠️ Also Apple-only in the same file: **incremental streaming**. `session.bytes(for:)` + `stream.lines`
> is Darwin-only; the Linux fallback is `session.data(for:)`, which buffers the entire response — so
> `session.streamResponse` on Linux delivers everything in one shot. And the three test suites that
> use `@Generable` are wrapped in `#if canImport(Darwin)`, strongly implying guided generation is
> Darwin-only too. Neither is mentioned in the README.

> 🔴 **GAP — nobody has verified any of this on Linux.** `apple/foundation-models-utilities` has
> **no CI, no Dockerfile, no Linux job and no platform matrix**. The `#if canImport(FoundationNetworking)`
> and `#if canImport(Darwin)` fallbacks are real and deliberate — beta 3 *added* the Linux image
> branch quoted above — but nothing in the repository proves the package compiles on Linux, and it
> requires a Linux `FoundationModels` module that is not evidenced anywhere in this corpus.

### 10.3 Core AI and MLX

- **`CoreAIVisionLanguageModel`** — added in `apple/coreai-models` PR #97 (merged), a
  `LanguageModel` + `CoreAIVLMExecutor` pair that **declares the `.vision` capability**. Usage, from
  the PR:
  ```swift prelude:guide-context
  let model = try await CoreAIVisionLanguageModel(resourcesAt: bundleURL)
  let session = LanguageModelSession(model: model)
  let response = try await session.respond(
      options: GenerationOptions(maximumResponseTokens: 256)
  ) { Attachment(cgImage); "What is in this image?" }
  ```
  With one inverted constraint worth knowing: **"An image attachment is required; a text-only prompt
  throws `unsupportedTranscriptContent`."** A VLM bundle is not a drop-in for a text model.
- **`MLXLanguageModel`** (in `ml-explore/mlx-swift-lm`) tests `capabilities.contains(.vision)` and
  throws `.unsupportedCapability` when the loaded model can't take images. The VLM side of MLX Swift
  is its own world (17 model families, a `MediaProcessing` layer, `VLMError.imageRequired` /
  `.singleImageAllowed`); see [Part 13 · MLX in Swift](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).

### 10.4 Private Cloud Compute — support settled, operating limits open

> ✅ **Image input on PCC is supported** — settled by two Apple sources, matching
> [Part 4 §13.1](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).
> WWDC26 session **319** ("building with Private Cloud Compute") demos an app that takes *"a
> markdown file, and we take the **text and images**, feed that into a `LanguageModelSession`, and
> generate a summary"* while describing PCC's large context window, and Apple's
> [multimodal prompting article](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting)
> explicitly recommends `PrivateCloudComputeLanguageModel` when image analysis needs more reasoning
> or context. Build PCC multimodal features with the same labelled `Attachment` surface this guide
> teaches, and keep an on-device fallback for availability, quota, and network failures.
>
> Apple's Origami sample shows the intended **architecture**: its multi-image analysis runs in the
> profile's `.brainstorm` branch, which is bound to `.model(serverModel)` — and `serverModel` is
> declared with Apple's own comment: *"Brainstorm and tutorial work best on a server model. The
> sample defaults to the on-device system model so it runs out of the box. To use Private Cloud
> Compute, request access to the managed `com.apple.developer.private-cloud-compute` entitlement …
> then replace the `serverModel` initialization with the line below.
> `// var serverModel = PrivateCloudComputeLanguageModel()`"*
> (`Origami/Models/OrchestratorProfile.swift:11-40`). The sample ships running on-device, so it
> corroborates the pattern rather than adding an independent PCC measurement.
>
> 🔴 **What remains open is operational, not the support question — and nothing addresses the
> economics.** The Apple documentation page for PCC
> (`adding-server-side-intelligence-with-private-cloud-compute`) publishes a capability table
> covering privacy, offline operation, usage limits, reasoning and context size — and **says nothing
> about vision**. The per-user daily quota is expressed in *requests* counted against the user's
> iCloud account, and the quota API exposes only coarse states (reached / below / approaching) — a
> developer asked for actual numbers and was told they don't exist (FB23378161). The 27.0 interface
> confirms `PrivateCloudComputeLanguageModel` **publicly exposes** `capabilities:
> LanguageModelCapabilities` via its `LanguageModel` conformance (✅ **SDK-verified**,
> `FoundationModels-27.0-macos.swiftinterface:98-101`), and `.vision` is a declared `Capability`
> (`:1511-1514`) — so the check is one property read. Specifically:
>
> - Whether a PCC request carrying five images costs the same quota as a text request: **unknown**.
> - Whether PCC has different image size or count limits than the on-device model: **unknown**.
> - Whether PCC's `capabilities` **contains** `.vision` on a real entitled device: **unknown** —
>   the property is SDK-verified readable; nobody in this corpus has printed it.
>
> **Do not assume parity with the on-device model.** Resolve by reading
> `PrivateCloudComputeLanguageModel.capabilities` on a 27.0 device with the PCC entitlement, then
> running the same image prompt against both models and comparing `quotaUsage` before and after.
> Full PCC coverage: [Part 4 · Private Cloud Compute](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md).

### 10.5 watchOS

`Attachment`'s availability includes `watchOS 27.0+ Beta`, and Apple's own C shim gates on
`#available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)`. But on watchOS the framework is
described as a **PCC-only** surface — the on-device model is never described as running on the watch
— which folds watchOS image support into the PCC operating-limits questions above.

One concrete watchOS bug worth knowing, because it is image-related: on **watchOS 27 beta 2**,
importing `FoundationModels` failed to build with

```
…/WatchOS27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/
FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15
Unable to resolve module dependency: 'CoreImage'
```

Apple's reply: *"This is a known bug."* (Forum thread 835987.) The likely cause is the new attachment
API pulling `CoreImage` into the interface on a platform that lacks it — which is a nice illustration
of how new the whole surface is.

---

## 11. Python, and the `fm` CLI

### 11.1 The Python SDK's image API

`apple/python-apple-fm-sdk` (announced March 2026, per Apple's own changelog) mirrors the Swift
surface closely enough that it is the fastest way to *experiment* with multimodal prompting — and,
per Apple's own positioning, the intended way to **evaluate** your Swift app's Foundation Models
features from a notebook.

```python
PromptComponent = Union[str, Attachment]
Prompt = Union[PromptComponent, list[PromptComponent]]

class Attachment(ABC):
    @abstractmethod
    def add_to_composed_prompt(self, composed_prompt): ...

class ImageAttachment(Attachment):
    def __init__(self, path: Path, label: Optional[str] = None): ...
```

> ✅ **VERIFIED** — `src/apple_fm_sdk/prompt.py`. A prompt is a `str`, a single `Attachment`, or a
> `list` mixing both.

Every shape the test suite exercises (`tests/test_image_prompts.py`, verbatim):

```python
from pathlib import Path
import apple_fm_sdk as fm

TEST_RESOURCES_DIR = Path(__file__).parent / "resources"
SIMPLE_IMAGE = TEST_RESOURCES_DIR / "test-simple-image.jpeg"
TEXT_DENSE_IMAGE = TEST_RESOURCES_DIR / "test-text-dense-image.png"

# text + image
image = fm.ImageAttachment(path=SIMPLE_IMAGE)
response = await session.respond(["What do you see in this image? Describe it briefly.", image])

# image only (single component, not a list)
response = await session.respond(fm.ImageAttachment(path=SIMPLE_IMAGE))

# list of images only
prompt: list[fm.PromptComponent] = [image1, image2]

# labelled attachments
image1 = fm.ImageAttachment(path=SIMPLE_IMAGE, label="image-a")
image2 = fm.ImageAttachment(path=TEXT_DENSE_IMAGE, label="image-b")
response = await session.respond([
    "I'm going to show you two labeled images.", image1, image2,
    "What do you see in image-a and image-b?"])

# guided generation with an image
result = await session.respond(["Analyze this image:", image], generating=ImageAnalysis)

# schema + image
generated_content = await session.respond(["Analyze this image:", image], schema=schema)
```

So: **text + image, image-only, list-of-images, labelled attachments, `generating=` and `schema=`
with an image** — all supported and all test-covered. Test resources are `.jpeg` and `.png`.

Five things that will bite you:

1. **`path` must be a `pathlib.Path`, not a `str`.** The initializer calls `path.is_file()`; a `str`
   raises `AttributeError` rather than a useful error.
2. **File path only — no in-memory images.** The Python surface is strictly `Attachment(imageURL:)`
   underneath. There is no `numpy`/`PIL`/bytes entry point. Write your array to a temp file.
3. **`ImagePromptError` is not a `FoundationModelsError`.** `PromptError` and `ImagePromptError`
   inherit from plain `Exception`, so `except fm.FoundationModelsError:` will **not** catch them.
   Apple's own test hedges with `pytest.raises((fm.ImagePromptError, fm.FoundationModelsError))`.
4. **Any iterable is expanded.** `_composed_prompt_from_prompt` checks `isinstance(prompt, Iterable)
   and not isinstance(prompt, str)` — so a tuple, a generator, even a `dict` (which iterates its
   *keys*) is silently treated as a component list. Pass a `list`.
5. **The error message names classes that no longer exist.** The `PromptError` text still says *"only
   str, Image, IdentifiedImage, and Attachment are supported"*; `Image` and `IdentifiedImage` were
   removed from the Python API in commit `da32e98`. Ignore the first two names.

### 11.2 The build-time SDK gate — a wheel can permanently lack image support

> ⚠️ **SILENT FAILURE (build-time flavour).** Image attachments in the Python SDK require the
> **macOS 27 SDK at build time** *and* macOS 27 at runtime. The custom PEP 517 backend probes
> `xcrun --sdk macosx --show-sdk-version` and only then passes `-Xswiftc -DFM_HAS_MACOS_27_SDK`:
>
> ```python
> # build_backend.py:148-152 — verbatim
> # `Attachment` (image support) only exists in the macOS 27+ SDK
> extra_swift_args = []
> sdk_major = _macos_sdk_major_version()
> if sdk_major is not None and sdk_major >= 27:
>     extra_swift_args += ["-Xswiftc", "-DFM_HAS_MACOS_27_SDK"]
> ```
>
> **A wheel built against an Xcode with a 26.x SDK compiles cleanly, installs cleanly, and then
> raises on every image:** `ImagePromptError: Failed to add attachment to prompt: the Xcode version
> used to build this package doesn't include macOS 27 SDKs`. Nothing about the *installed* package
> announces this. The runtime counterpart is `…: the current OS does not support attachment prompts`.
> If you distribute wheels, this is a build-matrix requirement, not a footnote.

The C-level surface confirms the shape and includes two vestigial entry points:

```c
FMComposedPromptAddImageError { None, UnsupportedOS, UnsupportedSDK, Unknown }

bool FMComposedPromptAddImage(FMComposedPrompt, const char *imagePath,
                              FMComposedPromptAddImageError *);            /* DECLARED, NOT IMPLEMENTED */
bool FMComposedPromptAddIdentifiedImage(FMComposedPrompt, const char *imagePath,
                                        const char *imageIdentifier,
                                        FMComposedPromptAddImageError *);  /* DECLARED, NOT IMPLEMENTED */
bool FMComposedPromptAddAttachment(FMComposedPrompt, const char *imagePath,
                                   const char *label,
                                   FMComposedPromptAddImageError *);
```

Only the third is implemented. `ctypesgen` will still emit bindings for the first two; calling them
is a link error, not a Python exception.

### 11.3 The file-descriptor leak — the sharpest image-specific bug in the corpus

> ⚠️ **SILENT FAILURE — until it isn't.** Issue **#17** (2026-07-03) against
> `apple/python-apple-fm-sdk`, reported verbatim:
>
> *"Under macOS, even though the soft file descriptor limit can be high (e.g., `1,048,575`),
> sequential predictions consistently fail after exactly **240-250 sequential calls with image
> attachments**. The system starts throwing a fatal **`OSError: [Errno 9] Bad file descriptor`** on
> any subsequent file system opens (including standard Python `open()`, `PIL.Image.open()`, or system
> plist reads)."*
>
> Two independent leak channels:
>
> 1. The native `FMComposedPrompt` was created but never released on the `respond()` paths — and
>    because it retains the `ImageAttachment`, **the image's file descriptor leaked with it**. Fixed
>    by PR **#18** (merged 2026-07-07) for the three `respond()` paths.
> 2. *"The native `LanguageModelSession` transcript history **automatically retains previous prompts
>    and attachments**. Therefore, in a single persistent session run, previous attachment file
>    descriptors are kept open throughout the session's lifetime."* — **this one is inherent**, not a
>    bug. Long-lived sessions hold every image's FD open.
>
> And by inspection, the fix did not cover everything: `_stream_response_basic` still creates a
> composed prompt and releases only the stream pointer, so **`stream_response()` leaks one
> `FMComposedPrompt` (and any image FDs) per call**. `SystemLanguageModel.token_count()` has the same
> shape. (Structurally clear from the source; **unverified at runtime**.)
>
> **Mitigations:** create a fresh session for image-heavy batch work rather than one long-lived
> session; prefer `respond()` over `stream_response()` in loops on `apple-fm-sdk` ≤ the version you
> can verify; and monitor your process's open FD count if you are doing hundreds of image calls.

Note channel 2 has a direct Swift analogue: the transcript retains attachments there too (§7.3). The
Python SDK just makes the cost visible as a file descriptor.

Deeper coverage of the Python SDK and the CLI:
[Part 5 · the `fm` CLI and Python SDK](../../part-05-prototyping-profiling-non-swift/references/02-fm-cli-and-python-sdk.md).

### 11.4 The `fm` CLI

`fm` ships pre-installed with macOS 27 and accepts image input. WWDC26 session 241 demos exactly the
use case you'd want:

> *"I have some pictures with random names like this one, `IMG_1234`. Let me just ask `fm` to
> **generate a file name based on the content inside the image**."*

> ✅ **MEASURED — stable macOS 27.** The project ran the CLI help comparison on build `26A428`.
> `fm respond` exposes `--image` and `--label`; stable help advertises only the `system` model and
> no longer exposes beta-5 `--model pcc`. Re-check help on the deployment OS because this surface
> changed between beta 5 and the public release.

```bash
# ✅ stable macOS 27 help-verified; quote paths in production scripts
fm respond --image ~/Pictures/IMG_1234.heic \
  "Suggest a descriptive filename for this photo. Reply with the filename only."
```

The subcommand names themselves (`fm respond`, `fm chat`, `fm schema`, `fm schema object`) are
stable-help verified. `/model` and `/save` remain beta-era interactive evidence; because stable
help no longer advertises PCC, do not assume `/model` retains the beta behavior.

---

## 12. Gotcha table, open gaps, and sources

### 12.1 The gotcha table

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 1 | EXIF orientation is not applied by every loader | Fluent, confidently wrong descriptions; worse on camera-roll photos than screenshots | Normalise orientation once at the app boundary; or always pass `orientation:` |
| 2 | A non-image URL still builds an `Attachment` | Empty/nonsense answer, or a generic error later | Validate `UTType` conforms to `.image` before attaching |
| 3 | Attachments accumulate in the transcript | `contextSizeExceeded` far sooner than in text chats | Budget with `response.usage`; compact deliberately |
| 4 | `summarizeHistory` does not preserve attachments | Model answers about images it can no longer see; `resolved(in:)` starts returning `nil` | Custom `historyTransform`; keep originals app-side and re-attach |
| 5 | `resolved(in:)` and label lookups are Optional | Results silently vanish from the UI | Handle and **log** the `nil` branch |
| 6 | `ImageAttachment.url` is Optional since beta 3 | Beta-1 code stops compiling; portable code stops working | In-memory attachments have no URL — use `.cgImage`, or attach by URL |
| 7 | In-memory images are Apple-only through `ChatCompletionsLanguageModel` | `unsupportedTranscriptContent` on Linux | Attach file URLs (or `data:` URLs) in portable code |
| 8 | An exhaustive `switch` over `Transcript.Segment` breaks — or worse, doesn't | Compile error (good) or images routed to `default:` (bad) | Audit every `default:` over `Segment`/`Entry`; add `@unknown default` |
| 9 | `CoreAIVisionLanguageModel` **requires** an image | `unsupportedTranscriptContent` on a text-only prompt | Don't treat a VLM bundle as a drop-in text model |
| 10 | Python: `ImageAttachment(path=)` needs a `Path` | `AttributeError` | Wrap in `pathlib.Path` |
| 11 | Python: `ImagePromptError` isn't a `FoundationModelsError` | Uncaught exception despite a broad `except` | Catch both |
| 12 | Python: a 26.x-SDK wheel silently lacks image support | `ImagePromptError: … doesn't include macOS 27 SDKs` | Build on Xcode 27; treat as a build-matrix requirement |
| 13 | Python: image FDs leak (~240-250 calls) | `OSError: [Errno 9] Bad file descriptor` | Fresh sessions for batch work; avoid `stream_response()` in image loops |
| 14 | Bounding boxes from the model are generated text | Boxes off by 1–2× object size, or clustered at the top | Localise with Vision or Core AI; describe with FM (§9) |
| 15 | The simulator punches out to the host macOS | Meaningless `LanguageModelError -1` | Test image input on a physical 27.0 device |
| 16 | A stream can yield **zero** partials when the turn produces only a tool call | Spinner never clears, on a *successful* call, with no error | Track "did I ever receive a partial"; clear the loading state on completion regardless (§6.2) |
| 17 | Attaching `UIImage`/`NSImage` may or may not carry orientation for you | Same silent quality loss as gotcha 1 | Normalise at the app boundary; don't rely on the container type (§5.1) |
| 18 | An unlabelled `Attachment` in an identity-dependent image workflow | `AttachmentSegment.label` is `nil`; `ImageReference` cannot provide your stable app handle, even though a generic tool may still run | `.label(_:)` every attachment once output or a tool must refer to it (§6.4) |

### 12.2 Every gap this guide declared

1. **Images in `Instructions`** — the `InstructionsRepresentable` conformance is now SDK-verified
   (`FoundationModels-27.0-macos.swiftinterface:2838-2847`); the semantics and caching behaviour
   are undocumented. (§1)
2. **Per-image token cost** — no Apple figure, no formula, and the forum thread that asked
   (833783) was never answered. The two circulating numbers (896 px, 576 tokens) are developer
   inference and a cross-backend community constant respectively. (§4.2)
3. **Whether `tokenCount(for:)` counts attachments** — **narrowed 2026-08-20:** on iPhone 15 Pro /
   iOS build `24A5408d`, every tested image size threw `LanguageModelError -1`; no image count was
   returned. The cost formula remains unknown. (§4.2)
4. ~~The `orientation:` parameter's type~~ — **✅ RESOLVED 2026-07-29**:
   `CGImagePropertyOrientation? = nil`, SDK-verified on every image init
   (`FoundationModels-27.0-macos.swiftinterface:2856-2860`, `:2410-2413`). (§5.1)
5. ~~`ImageAttachmentContent`'s members~~ — **✅ RESOLVED 2026-07-29**: the 27.0 interface shows it
   is *deliberately opaque* — `Sendable, Equatable`, no other public members; it exists as the
   phantom `Content` type parameter of `Attachment`
   (`FoundationModels-27.0-macos.swiftinterface:2850-2860`). You are not expected to construct one. (§1)
6. ~~`OCRTool` / `BarcodeReaderTool` API surface~~ — **✅ RESOLVED 2026-07-29**: both live in the
   `_Vision_FoundationModels` **cross-import overlay** (import both parents to get them);
   `init(name:description:)` is the whole configuration, `Arguments` is `Generable`, `Output` is
   opaque `some PromptRepresentable`
   (`_Vision_FoundationModels-27.0-macos.swiftinterface:14-83`). (§8.3)
7. ~~Modern Swift Vision request names beyond `ClassifyImageRequest`~~ — **✅ RESOLVED
   2026-07-29** from the captured `Vision-27.0-macos.swiftinterface` (table in §9.3). (§9.3)
8. **Quality/latency numbers for YOLOS, SAM 3, EfficientSAM in `apple/coreai-models`** — none exist
   in the repo. (§9.4)
9. **PCC image *operating limits*** — support itself is ✅ settled (session 319 plus Apple's
   multimodal prompting article; §10.4), but nothing addresses separate image quota, cost, size or
   count limits, and nobody has printed PCC's `capabilities` on an entitled device. Do not assume
   parity. (§10.4)
10. **Whether anything in `foundation-models-utilities` actually works on Linux** — no CI, no
    Dockerfile, no platform matrix. (§10.2)
11. **`fm` CLI flag spellings** — only semantic option names were ever spoken. (§11.4)
12. **Whether attachment ordering within a prompt matters** — Apple's doc snippets put text first,
    Origami puts images in the middle, a shipping third-party app puts images first, and nothing
    establishes a quality difference between the three. (§3.2)
13. **Whether the framework honours `UIImage.imageOrientation` / `NSImage` container orientation** —
    Apple's only multimodal sample attaches `UIImage`/`NSImage` and never passes `orientation:`,
    which is consistent with both "the framework reads it" and "the sample has no rotated photos."
    (§5.1)
14. **The `@Generable` container type that holds `[ImageAnalysis]` in Origami** — proven to exist by
    `partialResponse.content.images`, but its declaration is not quoted anywhere. (§6.2)

### 12.3 Sources, in precedence order

**Apple symbol pages and documentation articles** (harvested 2026-07-27 via `sosumi.ai` mirrors of
`developer.apple.com/documentation`):
`/foundationmodels` (the index and its "Prompt Attachments" topic group) ·
`/foundationmodels/analyzing-images-with-multimodal-prompting` · `/foundationmodels/attachment` ·
`/foundationmodels/imagereference` · `/foundationmodels/imageattachmentcontent` ·
`/foundationmodels/transcript` and its `imageattachment` / `attachmentsegment` children ·
`/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute` ·
`/updates/foundationmodels`.

**Apple sample code** — *Origami: Crafting a dynamic tutorial for Apple Intelligence*
(`OrigamiCraftingADynamicTutorialForAppleIntelligence.zip`, 200 MB, 61 Swift files, deployment target
iOS 27.0), the **only** Apple sample in the 2026 wave that attaches images. Files quoted:
`Models/DataModels/Photo.swift:65-67, 77-91` · `Models/Orchestrator.swift:596-616` ·
`Models/OrchestratorProfile.swift:11-40` · `Models/Error+DisplayMessage.swift:12-36` ·
`Brainstorm/ImageAnalysis.swift:11-27` · `Brainstorm/BrainstormModel.swift:120-123, 142-144, 168-171` ·
`Coach/CoachModel.swift:58-73` · `Coach/MovePhotoToStepTool.swift:12-38`. This is compiling,
shipping, first-party code and it **outranks** WWDC transcript reconstructions, community repos and
inference everywhere it disagrees with them.

Two other 2026 Apple samples were read and contain **no** multimodal code: *Book Tracker*
(Evaluations, macOS 27) and *"Searching indexed content with natural language"* (`SpotlightSearchTool`,
iOS 27). ⚠️ Two further samples that turn up in searches — the coffee/generative-game sample and the
SpeechAnalyzer sample — are **iOS 26 / WWDC25 leftovers, never refreshed**, and are not cited here as
2026 evidence.

**Apple open-source repositories** — `github.com/apple/foundation-models-utilities`
(`ChatCompletionsLanguageModel.swift`, `skills/foundation-models-language-model-protocol/SKILL.md`,
commit `376ca60e61985369d5067bd3c575bdb6a13f0e1b`) · `github.com/apple/python-apple-fm-sdk`
(`prompt.py`, `FoundationModelsCBindings.swift`, `build_backend.py`, `tests/test_image_prompts.py`,
issues #17/#18) · `github.com/apple/coreai-models` (`CoreAIObjectDetector/`, `CoreAIImageSegmenter/`,
`CoreAIShared/Image/`, `models/{yolo,sam3,efficient-sam}/`, PR #97).

**Apple Developer Forums** — **838613** (image input and locating things within an image; the
Apple-Designer answer redirecting to Vision) · **833642** (the Frameworks-Engineer answer on
resolution, image count, format support and routing) · **833783** (image size/format vs other VLMs —
*unanswered*) · **833666** (no NPU priority API) · **833706** (`summarizeHistory` condenses to a
`.prompt` entry) · **835987** (watchOS `CoreImage` build break) · **835974** (PCC quota opacity,
FB23378161) · **831404** (the simulator punch-out).

**WWDC26 transcripts** — **241** *What's new in Foundation Models* (the source-type list, the
any-size/any-aspect-ratio quote, the token/latency caveat, the Vision tools) · **334** *Foundation
Models on macOS* (the `fm` CLI image option, the Python SDK) · **319** *Private Cloud Compute* (the
text-and-images demo behind §10.4's settled support claim) · **339** *Bring an LLM provider to the Foundation Models
framework* (capabilities and routing).

**Community** — [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) (a shipping multi-backend app: the `for`-loop prompt builder,
the `promptTokensPerImage = 576` constant, `GenerationOptions(sampling:)`). Marked as community
throughout; none of its numbers are Apple's.

### 12.4 Where to go next

- Prompt-builder fundamentals and session lifecycle → [01 · sessions and prompting](01-sessions-and-prompting.md)
- `@Generable`, `@Guide`, partial snapshots → [02 · guided generation and streaming](02-guided-generation-and-streaming.md)
- `Tool`, tool-calling modes, `ImageReference` arguments in anger → [03 · tools and tool calling](03-tools-and-tool-calling.md)
- `OCRTool`, `BarcodeReaderTool`, `SpotlightSearchTool` → [04 · Spotlight RAG and system tools](04-spotlight-rag-and-system-tools.md)
- The error taxonomy, availability, guardrails and refusals → [06 · availability, errors and guardrails](06-availability-errors-and-guardrails.md)
- Budgeting a 4K window that now contains pictures → [Part 3 · context window and KV cache](../../part-03-context-profiles-agentic/references/01-context-window-and-kv-cache.md)
- PCC eligibility, entitlement, quota UX → [Part 4 · Private Cloud Compute](../../part-04-beyond-the-built-in-model/references/01-private-cloud-compute.md)
- Running your own detection/segmentation model → [Part 7 · Core AI: the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md)
- Regression-testing an image feature across OS updates → [Part 6 · Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)
