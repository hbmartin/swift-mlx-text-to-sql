# Shipping models: Background Assets, per-architecture variants, and updates

**Part 15 · Shipping and operating on device · Reference 01**

**Version floor: iOS 27.0, iPadOS 27.0, macOS 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0 — all
Beta — plus Xcode 27 and a separately-downloaded Metal Toolchain.** Everything in this guide that
touches `CoreAI` is 27.0-only. Apple's framework page states the platform list verbatim:

> "Available on: iOS 27.0+ Beta, iPadOS 27.0+ Beta, Mac Catalyst 27.0+ Beta, macOS 27.0+ Beta,
> tvOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta"

✅ **VERIFIED** — `developer.apple.com/documentation/coreai/`, harvested 2026-07-27
(`notes/web/apple-docs-coreai.md:43-44`).

Two version caveats that bite immediately, both verified:

- ⚠️ **The individual symbol pages disagree with the framework page.** Every per-symbol
  `metadata.platforms` array in Apple's DocC JSON — `coreai/aimodel`, `coreai/ndarray`,
  `coreai/inferencefunction` — **omits macOS and Mac Catalyst**, while the `declarations` block of
  the *same* JSON lists Mac Catalyst but still not macOS. This is almost certainly a
  docs-generation defect: the Core AI Debugger requires a macOS 27 host, `coreai-build` runs on
  macOS, and the Instruments template runs on macOS. Treat **macOS 27 as supported** and do not
  write availability annotations off the symbol pages. ✅ VERIFIED
  (`notes/web/apple-docs-coreai.md:65-76`).
- ⚠️ **Ahead-of-time compilation has a much narrower hardware floor than the framework.** Apple's
  AOT article carries this NOTE verbatim: *"Ahead-of-time compilation only compiles for devices
  that support Apple Intelligence, including iPhone or iPad with the A17 Pro chipset or later, a
  Mac with the M1 chipset or later, or Apple Vision Pro with the M2 chipset or later."*
  ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1421-1422`). Older devices get no `.aimodelc` at
  all and must fall back to full on-device specialization from the portable `.aimodel`. This is
  stated in the documentation and **in neither WWDC session**.

Nothing in this guide requires Apple Intelligence to be *enabled*, and nothing here uses
`SystemLanguageModel`. This is the plumbing under a bring-your-own-model feature.

---

## What this covers

This is the operational guide: **how a model actually reaches a user's device, and how it gets
replaced later.** It is the guide you need after the model works on your desk and before you press
Submit for Review.

The motivating constraint is a size problem, and it is worth stating in Apple's own words before
anything else. In WWDC26 session 326, the presenter is building a language-learning feature on top
of SAM 3 (segmentation) plus Qwen3 0.6B (card generation), shipping it as an update to an existing
app, and hits this:

> "My first-run experience gives me a natural place to explain the feature and prepare for a smooth
> first launch. But **I'd been assuming the models would just be bundled with the app and when I
> checked, they're adding over 1 GB to my download size. That hits everyone who updates, even
> people who'll never touch this feature.**"

✅ VERIFIED — WWDC26 session 326, transcript lines 140-149, captured in
`notes/transcripts/coreai-intro.md:1680`.

That single sentence is the spine of this guide. Two sub-1B-class models bundled into an app binary
cost over a gigabyte of download, charged to every updater including the ones who will never open
the feature. Everything below is the machinery for not doing that.

Sections:

- **§1 — The size problem.** Why bundling is the wrong default for an optional AI feature, what
  "over 1 GB" was actually made of, and what the alternative costs you in complexity.
- **§2 — The feature-introduction screen.** The UI pattern Apple's own session arrives at, why it
  exists for three separate reasons at once, and how it becomes the place you hide specialization
  latency.
- **§3 — Background Assets.** What Apple actually says about using it for model files, what we can
  verify about the API surface, and — honestly — what we cannot. Includes a design that keeps your
  Core AI code independent of the delivery mechanism.
- **§4 — Per-architecture variants.** `coreai-build compile`, the `.aimodelc` output naming
  convention, `AIModel.deviceArchitectureName`, and the arch-code enumeration problem.
- **§5 — ⚠️ SILENT FAILURE: a green compile that the device rejects.** `coreai-build compile`
  exits 0 for architectures no device will load. The failure surfaces in a user's hands.
- **§6 — Specialization after download.** The cache, the policies, `specialize(...)`, and why the
  first-run screen is where this belongs.
- **§7 — Updating a model.** The full replace sequence, asset versioning, and keeping the app
  working while an update is in flight.
- **§8 — ⚠️ SILENT FAILURE: the bookmark that quietly stops working.** `init?(resolvingBookmark:)`
  returns `nil`, does not throw, and the recovery path is a multi-gigabyte re-download. Persist a
  record, never a bare bookmark.
- **§9 — ⚠️ SILENT FAILURE: two options structs, two multi-gigabyte specializations.**
  `SpecializationOptions` is part of the cache key and has a mutable property. The fix is
  structural.
- **§10 — App groups.** Sharing one specialization across an app and its extensions with
  `AIModelCache(appGroup:)`.
- **§11 — Storage hygiene.** Cache policies, when the system may reclaim, deleting the source
  asset, and how to report model storage to the user.
- **§12 — The App Store reality.** There is no Required Device Capability for Apple Intelligence.
  What Apple's own staff recommend instead, and what that means for pricing and review.
- **§13 — Checklist and declared gaps.**

## What this does *not* cover

- **Converting a PyTorch model to `.aimodel`.** That is
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md). This guide starts from an `.aimodel` bundle
  that already exists and already runs.
- **The Core AI runtime API** — `AIModel` → `InferenceFunction` → `NDArray`, states, views.
  [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md).
- **Compression and quantization**, which is the other half of the size story and often the larger
  half. [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Profiling specialization** with the Core AI instrument and debug gauge.
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md).
- **Apple's own `SystemLanguageModel`**, which ships with the OS and has no distribution story at
  all — that is exactly why it is attractive and exactly why §12 exists.

## What you need

- **Xcode 27** with the **Metal Toolchain** installed. It is not installed by default and its
  absence is a build failure, not a warning. Apple, verbatim: *"If the Metal toolchain isn't
  included, builds that include `.aimodel` files fail with a missing Metal compiler error."*
  ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1146`). Install it from **Xcode > Settings >
  Components > Other Components**, or:

  ```shell
  % xcodebuild -downloadComponent MetalToolchain
  ```

  ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1150`).

- **A physical device of every architecture class you intend to ship to.** §5 exists because there
  is no way to validate an architecture choice on a Mac. A green CI build proves nothing about
  whether the artifact loads.

- **An Apple Developer account able to configure Background Assets**, if you take the hosted route.
  §3 is candid about how much of that pipeline we could and could not verify.

- **Roughly 3× your model's size in free space on the build machine**, because `coreai-build`
  emits one artifact per architecture and — community-measured — each `.aimodelc` runs about
  **2× the size of the source `.aimodel`** (see §4.5 for the attribution).

---

## Evidence markers used in this guide

Per the series conventions:

> ✅ **VERIFIED** — quoted from an Apple documentation page, a header, a shipping source file, or
> an Apple-staff forum answer. The citation follows the claim.

> 🟡 **RECONSTRUCTED** — the concept is attested, but the exact spelling is inferred. Treat the
> shape as right and the identifiers as provisional.

> 🔴 **GAP** — we could not verify this and are saying so rather than guessing. Each gap box names
> what is unknown, what would resolve it, and gives a safe default.

One class of evidence deserves a standing caveat before §4. A large amount of what is *known* about
per-architecture compilation comes from a **community archive** (`notes/repos/john-rocky-models.md`,
`notes/repos/issues-coreai-stack.md`) whose measurements were taken by one person on one Mac and one
iPhone, on beta OSes, and from GitHub issues on `apple/coreai-models`. Those are cited as
**community-measured** throughout, with hardware and date. They are not Apple statements. They are
also, in several places, the *only* source that exists — Apple's documentation names an
architecture flag without ever printing a single architecture value.

---

## 1. The size problem

### 1.1 What "over 1 GB" was made of

The number comes from a real feature demo, not a hypothetical. WWDC26 session 326 builds a
language-learning app: point the camera at an object, segment it, generate a vocabulary card. Two
models are involved, both individually modest:

- **SAM 3** — Segment Anything, used for the segmentation step.
- **Qwen3 0.6B** — a sub-one-billion-parameter LLM, used for card generation.

The presenter narrates the discovery verbatim (WWDC26 session 326, 140-149; ✅ VERIFIED via
`notes/transcripts/coreai-intro.md:1678-1681`):

> "Before I make that change though, I want to step back and think more broadly about my
> **deployment strategy** for this feature. There are a few things I want to get right. **I'm
> shipping this as an update to my existing app, so I want the feature to be discoverable but not
> required. Users who try it should have a great experience, and users who don't should feel just
> as great about the app as before.**
>
> My first-run experience gives me a natural place to explain the feature and prepare for a smooth
> first launch. But **I'd been assuming the models would just be bundled with the app and when I
> checked, they're adding over 1 GB to my download size. That hits everyone who updates, even
> people who'll never touch this feature.**"

Notice the arithmetic. Neither model is large by 2026 standards. "Sub-1B parameter LLM" is the
*small* end of what Core AI is pitched at — session 324 claims a scaling range that tops out at a
**70-billion-parameter LLM** (✅ VERIFIED, `notes/transcripts/coreai-intro.md:54`). And yet two
small models together crossed a gigabyte.

The reason is that model *file* size is not parameter count. It is parameter count × storage dtype
× (1 + tokenizer + metadata + any companion graphs), and for a vision model it also includes an
image encoder that has nothing to do with the LLM's parameter budget. Apple's own Xcode model
viewer separates the two concepts explicitly — the General tab shows **compute types** ("the
representations used during inference") separately from **storage types** ("the representations
used for the model's weights on disk") ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1156-1159`). It shows them separately because they diverge, and
the one that lands in your app download is the storage type.

So: run the number before you design the feature. `AIModelAsset` will tell you without loading
anything:

```swift compile:27 imports:Foundation
import CoreAI

/// Reports the on-disk footprint and operation mix of an `.aimodel` bundle
/// without specializing it. Cheap: it reads the asset header only.
///
/// Availability: CoreAI is iOS/iPadOS/macOS/visionOS/watchOS/tvOS 27.0+ (Beta).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
func describeAsset(at url: URL) throws {
    guard AIModelAsset.isValid(at: url) else {
        print("Not a Core AI model asset: \(url.lastPathComponent)")
        return
    }

    let asset = try AIModelAsset(contentsOf: url)

    // `includingStatistics: false` is the fast path — version info and function
    // signatures only. Apple: "Including model statistics is considerably slower
    // for large models."
    guard let summary = try asset.summary(includingStatistics: true) else {
        print("No program bytecode in \(url.lastPathComponent)")
        return
    }

    print("compute types: \(summary.computeTypes)")
    for storage in summary.storageTypes {
        print("  storage \(storage.typeName): \(storage.count)")
    }
    for function in summary.functions {
        let ins  = function.inputs.map(\.name).joined(separator: ", ")
        let outs = function.outputs.map(\.name).joined(separator: ", ")
        print("  fn \(function.name): (\(ins)) -> (\(outs))")
    }
}
```

✅ **VERIFIED** — every symbol here is from Apple's `AIModelAsset` reference page:
`init(contentsOf:) throws`, `static func isValid(at:) -> Bool`,
`func summary(includingStatistics: Bool) throws -> AIModelAsset.Summary?`, and `Summary`'s
`computeTypes: [String]`, `storageTypes: [AIModelAsset.Summary.StorageType]`,
`functions: [AIModelAsset.FunctionDescriptor]`, with `StorageType` = `(typeName: String, count:
Int)` and `FunctionDescriptor` = `(name, inputs, outputs, states)` where each entry is an
`AIModelAsset.ValueDescriptor` = `(name: String, typeName: String)`
(`notes/web/apple-docs-coreai.md:180-304`).

Apple's parameter documentation for `includingStatistics` is worth quoting because it is the
tradeoff: *"A Boolean value that indicates whether to read detailed model statistics. If `false`,
the summary contains only version information and function signatures. **Including model statistics
is considerably slower for large models.**"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:199`). Use `false` on a hot path; `true` in a build script.

> 🟡 **RECONSTRUCTED** — `AIModelAsset.isValid(at:)`'s discussion says it checks that *"the
> extension is one of the known model asset extensions"* (plural), but Apple never enumerates them,
> so whether `isValid` accepts a compiled `.aimodelc` is not stated. The community iOS app
> `noema-ios` treats both as valid — its `modelExtensions` set is literally
> `["aimodel", "aimodelc"]` and it calls `AIModelAsset.isValid(at:)` on whichever it resolved
> (community source, `notes/repos/noema-ios.md:417-419, 618`). Treat "`.aimodelc` passes
> `isValid`" as probable but unconfirmed, and never let a `false` result be the only thing standing
> between you and a crash.

### 1.2 An `.aimodel` is a directory

This trips people up in build scripts and in every `FileManager` size calculation. An `.aimodel` is
a **bundle/directory**, not a single file. Apple's own conversion docs say so:

> "`AIProgram.save_asset(path)` writes the program out as an `.aimodel` directory"

and, from a Core AI tutorial notebook: *"An `.aimodel` is a directory. List its contents and total
size to confirm the …"*

✅ VERIFIED (`notes/transcripts/coreai-intro.md:171-174`, quoting
`repos/apple__coreai-torch/docs/coreai-core/tutorials/construct-a-graph.ipynb`). Finder and Xcode
present it as a package, so it *looks* like a file. `attributesOfItem(atPath:)[.size]` on it will
give you a directory inode size, typically a few hundred bytes, and you will conclude your 1.8 GB
model is tiny.

The compiled form is the same. `apple/coreai-models`' bundle reader has an explicit guard for
exactly this confusion, and the comment is the clearest statement of it anywhere:

> *"a compiled `.aimodelc` is itself a directory holding its own unrelated metadata.json, which
> would otherwise parse as a bogus 0.1 bundle and surface a misleading 'unsupported
> metadata_version' error"*

✅ VERIFIED — shipping source, `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift:122-131`, via
`notes/repos/apple-coreai-models.md:323`. The resulting error case is
`ModelBundle.BundleError.pointedAtModelAsset(URL)`, thrown *before any filesystem read*.

Size a model directory recursively, then:

```swift compile:27
import Foundation

/// Total bytes consumed by a Core AI model bundle (`.aimodel` or `.aimodelc`),
/// which are directories, not files.
///
/// Uses allocated size rather than logical size, because that is what the user
/// sees in Settings > General > iPhone Storage and what storage pressure acts on.
func bundleSizeOnDisk(at url: URL) throws -> Int64 {
    let keys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
    ]

    // A bundle path may itself be a regular file on some future format revision;
    // handle both shapes rather than assuming.
    let rootValues = try url.resourceValues(forKeys: keys)
    if rootValues.isRegularFile == true {
        return Int64(rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0)
    }

    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: []          // deliberately NOT .skipsPackageDescendants
    ) else { return 0 }

    var total: Int64 = 0
    for case let child as URL in enumerator {
        let values = try child.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else { continue }
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    return total
}
```

Note the comment on `options: []`. `FileManager.DirectoryEnumerationOptions.skipsPackageDescendants`
is the default-looking choice in a lot of sample code and it will silently return zero for a
`.aimodel`, because the OS treats it as a package. This is a plain Foundation API, not a Core AI
one, so it is not marked — but it is the single most common way a model-storage screen ends up
reporting 0 bytes.

### 1.3 Why "just bundle it" is worse than it looks

Three distinct costs, only one of which is obvious.

**Cost 1 — the download, charged to everyone.** This is the one session 326 names. An app update is
not a per-feature transaction; the user downloads the binary. Apple's App Store does thin the
binary per device, but a model asset in the app bundle is not architecture-thinnable in the way
`arm64` slices are — the `.aimodel` is *portable by design*, one artifact for all devices. Apple's
own framing: *"The `.aimodel` file contains your model in a **portable format that works across
Apple devices**."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1260`). Portability is what makes it
un-thinnable.

**Cost 2 — you cannot fix the model without an app release.** Every model bug, every quality
regression, every tokenizer fix becomes a binary submission with a review cycle. This matters more
than it sounds, because the model is the part of an AI feature most likely to need iteration and
the part least likely to be covered by your test suite.

**Cost 3 — you pay the specialization cost anyway, and at the worst moment.** Bundling does not
avoid specialization. A bundled `.aimodel` is still portable IR; it still has to be compiled and
specialized on the device before it can run. Apple, verbatim:

> "When you load a `.aimodel` file with `AIModel`, Core AI performs **specialization**, the process
> of optimizing the model for the current device's hardware. … Before the model can run, Core AI
> specializes it for the current device, producing **executable code tied to that device's hardware
> and OS version**."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1260`). So bundling buys you a bigger download and
saves you nothing at first run. That is a bad trade in both directions at once, and it is why the
solution shape in §2 is not "download instead of bundle" but "download *and* pre-specialize, both
behind an explicit opt-in."

### 1.4 What downloading costs you

Honesty about the other side of the ledger. Moving models out of the bundle buys the three wins
above and costs you:

- **A download UI with real failure modes** — no network, metered network, cancelled mid-transfer,
  app backgrounded, device rebooted, storage full at 94%.
- **A versioning problem.** The app binary and the model are now two independently-versioned
  artifacts that must remain compatible. §7 is entirely about this.
- **A "feature not ready yet" state** that every call site touching the model must handle.
- **Per-architecture variants**, if you also adopt AOT compilation — one asset becomes N assets
  (§4).
- **Storage the user can see and will want to delete** (§11).

None of these is optional once you start. Budget for them.

---

## 2. The feature-introduction screen

### 2.1 How the session arrives at it

The first-run screen in session 326 is not presented as a design flourish. It is presented as the
resolution of a *performance* bug, and the sequence matters because it is how you will find the
same bug in your own app.

The presenter demos the feature. It hangs:

> "Now let's see it in action. I'll take a photo… and we're waiting. **The segmentation hasn't come
> back yet, so we can't get to card generation. Something is clearly slow here.**
> I know from my code that **I show this spinner when I'm first instantiating my SAM 3 model and
> sending it a prompt**. Let's see what's going on.
> **I took a trace with the new Core AI instruments, and sure enough there's a model load event
> right at that point, with a large sub-event for specialization.**"

✅ VERIFIED — WWDC26 session 326, 119-140, via `notes/transcripts/coreai-intro.md:1662-1666`.

🔑 **The Instruments signature to look for is a model load event with a large "specialization"
sub-event.** That is what the trace shows and it is the diagnostic fingerprint for this whole class
of problem.

Then the reasoning that produces the screen:

> "While future loads are from the cache and are fast, **that first time is something I need to
> plan for**. **Having that happen right in the middle of the user experience is... probably not
> great.** So when should I do it? **I could kick it off at launch or run it in the background but
> that feels wasteful if the user isn't even interested in this feature yet.**
> **I think a better idea is to create a dedicated first-run experience, where I can move this work
> to happen while the user is learning about the feature for the first time. This keeps model
> loading and specialization out of the interactive flow.**"

✅ VERIFIED — same source, `notes/transcripts/coreai-intro.md:1667-1669`.

The same recommendation appears independently in session 324, stated as a rule rather than a story:

> "**It is recommended you avoid having model specialization occur within user interactive flows.**"

✅ VERIFIED — WWDC26 session 324, 141-147, via `notes/transcripts/coreai-intro.md:914`.

### 2.2 The screen does three jobs, and that is the point

A feature-introduction screen is usually justified on one ground: onboarding. Here it earns its
place three times over, and each job makes the other two cheaper.

**Job 1 — it explains the feature.** Standard onboarding. Nothing special.

**Job 2 — it makes the download conditional on consent.** This is the part that solves §1. The
button, not the app update, triggers the transfer:

> "**So instead, I'll have my feature introduction screen include a button that only triggers the
> model download if the user actually wants to try it. I'll use Background Assets for this.**"

✅ VERIFIED — `notes/transcripts/coreai-intro.md:1681`.

**Job 3 — it is a socially acceptable place to be slow.** A progress bar on a screen the user is
reading is not latency; a progress bar in the middle of a camera flow is. The presenter is explicit
that this is the mechanism:

> "When a user says they want to give the feature a try, **I request the model assets and show them
> the download progress. Once that's done, I kick off specialization.**"

✅ VERIFIED — `notes/transcripts/coreai-intro.md:1688`.

And equally explicit that it does not fully solve the problem on its own:

> "The specialization is no longer interrupting the main experience **but it's still taking a
> while. That's a bit of an awkward waiting time for the user experience.**"

✅ VERIFIED — `notes/transcripts/coreai-intro.md:1689`. That residual awkwardness is what §4's
ahead-of-time compilation attacks. The screen buys you cover; AOT reduces what you need cover for.

### 2.3 A concrete preparation state machine

Here is the state machine that screen drives. It is deliberately delivery-agnostic — §3 explains
why — and it is deliberately explicit about every terminal state, because "prepared / not prepared"
is a two-state model that does not survive contact with a 1.8 GB download.

```swift compile:27
import Foundation
import CoreAI

/// Everything the feature-introduction screen needs to render.
///
/// Note that `.needsSpecialization` and `.specializing` are distinct states from
/// the download states. A user can have the bytes and still not have a runnable
/// model — that is the whole reason this screen exists.
enum ModelPreparationState: Equatable {
    /// No local copy, no download in flight. The opt-in button is showing.
    case notStarted

    /// Bytes are moving. `fraction` is 0...1, or nil if the source cannot report
    /// a total (a surprising number of hosts cannot).
    case downloading(fraction: Double?)

    /// Bytes are local. Specialization has not been attempted.
    case needsSpecialization

    /// `AIModel.specialize(...)` is running. This step reports no progress —
    /// see §6.4 — so the UI must be honest about that rather than faking a bar.
    case specializing

    /// A specialized asset exists in the cache and the model is loadable.
    case ready

    /// Terminal failure with a user-facing reason and a retry affordance.
    case failed(ModelPreparationFailure)
}

/// Failures owned by transport and local materialization, before Core AI sees
/// the asset. Every `ModelDelivery` implementation maps its underlying errors
/// into this type.
enum ModelDeliveryFailure: Error, Equatable {
    case network(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case fileSystem(String)
}

enum ModelPreparationFailure: Error, Equatable {
    case network(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case delivery(String)
    /// The downloaded artifact did not pass `AIModelAsset.isValid(at:)`.
    case corruptAsset
    /// Specialization threw. `message` is the localized description.
    case specializationFailed(String)
    /// No compiled variant matches this device's architecture. See §5.
    case noVariantForArchitecture(String)
}
```

The driver uses separate error scopes for delivery and specialization. A transport or staging error
must not be relabeled as a Core AI compiler failure, and a specialization error must not be presented
as a network retry.[^phase-specific-failures]

```swift prelude:guide-context
import Observation

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
@MainActor
@Observable
final class ModelFeatureCoordinator {

    private(set) var state: ModelPreparationState = .notStarted

    private let delivery: ModelDelivery          // §3 — the delivery abstraction
    private let options: SpecializationOptions   // §9 — ONE factory, always

    init(delivery: ModelDelivery, options: SpecializationOptions) {
        self.delivery = delivery
        self.options = options
    }

    /// Call this when the screen appears — cheap, no side effects, no download.
    func refreshState() {
        guard let localURL = delivery.localURLIfPresent() else {
            state = .notStarted
            return
        }
        // `model(for:options:)` NEVER specializes. It is a pure cache probe.
        if (try? AIModelCache.default.model(for: localURL, options: options)) != nil {
            state = .ready
        } else {
            state = .needsSpecialization
        }
    }

    /// Call this from the opt-in button. This is the only place a multi-gigabyte
    /// transfer may start.
    func userOptedIn() async {
        let localURL: URL
        if let existing = delivery.localURLIfPresent() {
            localURL = existing
        } else {
            state = .downloading(fraction: 0)
            do {
                localURL = try await delivery.fetch { [weak self] fraction in
                    Task { @MainActor in self?.state = .downloading(fraction: fraction) }
                }
            } catch let failure as ModelDeliveryFailure {
                switch failure {
                case .network(let message):
                    state = .failed(.network(message))
                case .insufficientStorage(let required, let available):
                    state = .failed(.insufficientStorage(
                        requiredBytes: required, availableBytes: available))
                case .fileSystem(let message):
                    state = .failed(.delivery(message))
                }
                return
            } catch {
                // A conformer violated the ModelDelivery contract. Keep it out
                // of the Core AI specialization bucket nonetheless.
                state = .failed(.delivery(error.localizedDescription))
                return
            }
        }

        guard AIModelAsset.isValid(at: localURL) else {
            state = .failed(.corruptAsset)
            return
        }

        state = .specializing
        do {
            // Discardable result: we only want the cache entry warmed here.
            _ = try await AIModel.specialize(
                contentsOf: localURL,
                options: options,
                cache: .default,
                cachePolicy: .persistent
            )
            state = .ready
        } catch {
            state = .failed(.specializationFailed(error.localizedDescription))
        }
    }
}
```

API grounding for the Core AI calls above, all ✅ **VERIFIED** from Apple's reference pages
(`notes/web/apple-docs-coreai.md:111-128, 1005-1017, 1264-1300`):

```swift illustrative
// AIModelCache
final func model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?

// AIModel
@discardableResult
static func specialize(contentsOf modelURL: URL,
                       options: SpecializationOptions = .default,
                       cache: AIModelCache = .default,
                       cachePolicy: AIModelCache.Policy = .default) async throws -> AIModel

// AIModelAsset
static func isValid(at url: URL) -> Bool
```

And the crucial semantic on the cache probe, verbatim from Apple: *"If this cache holds a
specialized asset from previously specializing the model at `modelURL` with the specified
`options`, this method loads and returns the model. **This method never performs specialization.**"*
✅ VERIFIED (`notes/web/apple-docs-coreai.md:1027`).

This is the API that makes `refreshState()` safe to call on every appearance of the screen. Session
324 names exactly this use:

> "First, Core AI gives you **programmatic access to the default model cache for your app**. You can
> **request to load models directly from it**. If **nil is returned, it is not present and requires
> specialization**. You can use this to **gate features or inform the users that they may need to
> wait a bit while your app prepares the model**."

✅ VERIFIED — WWDC26 session 324, 149-152, via `notes/transcripts/coreai-intro.md:921`.

### 2.4 Apple's own minimal version of this

For comparison, Apple's documentation ships a much shorter form of the same idea, and it is worth
reading because it shows the intended shape without the state machine:

```swift illustrative
func loadModel(from modelURL: URL) async throws -> AIModel {
    // The default cache stores all specialized assets for your app bundle.
    let cache = AIModelCache.default

    // A non-`nil` result means the model was previously specialized and cached.
    if let model = try cache.model(for: modelURL, options: .default) {
        return model
    }

    // No cached specialization exists. Inform the person and specialize now.
    Task { @MainActor in
        informUser("Preparing AI features. This may take a while…")
    }

    // This call performs specialization, caches the result, and returns the model.
    return try await AIModel(contentsOf: modelURL, options: .default)
}
```

✅ VERIFIED verbatim — Apple's *Managing model specialization and caching* article, captured at
`notes/web/apple-docs-coreai.md:1264-1282`.

Two things to notice. First, `informUser` is fired and forgotten in a detached `Task` — Apple is
not modelling a state machine, just a message. Second, the fallback path calls
`AIModel(contentsOf:options:)`, which **both specializes and returns a live model**, whereas
`AIModel.specialize(...)` lets you warm the cache without holding a model. The distinction matters
for memory: an `AIModel` is documented as lightweight — *"The model instance is lightweight and
doesn't own weights or intermediate buffers. Those resources belong to the functions you load from
it"* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:105`) — but it does **pin its cache entry**,
which has consequences for deletion (§7.4).

### 2.5 What the screen must never do

- **Never start the download from `application(_:didFinishLaunchingWithOptions:)` or a `.task`
  modifier on your root view.** That is the "kick it off at launch" option session 326 explicitly
  rejects as *"wasteful if the user isn't even interested in this feature yet."*
- **Never specialize on the first inference.** That is the bug the session opens with.
- **Never show an indeterminate spinner for specialization without text.** Specialization on a
  large model is measured in *seconds to minutes*, not milliseconds — see §6.5 for community
  numbers. A bare spinner reads as a hang.
- **Never make the opt-in irreversible.** Whatever the user turned on, they must be able to turn
  off and reclaim the storage (§11.5). If the only way to delete a gigabyte is to delete the app,
  a fraction of your users will delete the app.

---

## 3. Background Assets

### 3.1 What Apple actually says

Background Assets is the framework Apple names, in three independent places, as the delivery
mechanism for model files. All three are worth having in front of you, because together they are
the entirety of the first-party guidance on this topic.

**From the Core AI ahead-of-time compilation article** (✅ VERIFIED,
`notes/web/apple-docs-coreai.md:1456`):

> "It's recommended to **host the compiled assets remotely and download the matching variant to the
> device at runtime**, because each device only uses one of them. The **`BackgroundAssets`**
> framework can manage downloads, installs, and updates for your hosted model files."

**From WWDC26 session 326** (✅ VERIFIED, `notes/transcripts/coreai-intro.md:1681`):

> "**So instead, I'll have my feature introduction screen include a button that only triggers the
> model download if the user actually wants to try it. I'll use Background Assets for this.** If you
> want to dig into the details, check out **'Discover Apple-Hosted Background Assets' from last
> year's WWDC**."

**From an Apple Frameworks Engineer on the Developer Forums**, thread 829108, in the answer that
retired custom adapters (✅ VERIFIED, `notes/forums/forum-pain-points.md:251-253`):

> "@alex_und3r, as we announced at WWDC26, custom adapters are unfortunately no longer supported as
> of OS 27. Instead, you can use the base machine-learning models that are available on people's
> devices or provide your own custom models using Core ML or Core AI. **Background Assets remains a
> great way to deliver custom models to your users.**"

Three separate Apple sources, one recommendation. There is no ambiguity about *what* to use. There
is considerable ambiguity about *how*, and the next section is about that.

### 3.2 🔴 GAP — the 2026 Background Assets API surface for Core AI

> 🔴 **GAP.** Our corpus contains **no Apple sample-code project, no WWDC26 session transcript, and
> no Apple documentation page** that shows Background Assets being used to deliver a `.aimodel` or
> `.aimodelc`. The Core AI AOT article names the framework in one sentence and links away. Session
> 326 names it in one sentence and refers the viewer to a **WWDC25** session
> ("Discover Apple-Hosted Background Assets") that is **not in our transcript corpus**.
>
> **What is unknown:** the exact 2026 spellings for declaring an asset pack containing a model
> bundle; whether a `.aimodel`/`.aimodelc` *directory* can be an asset-pack member as-is or must be
> archived; how per-architecture variants are expressed in a manifest; whether Apple hosting has a
> per-asset size ceiling that a multi-gigabyte LLM would exceed; and what the extension point is
> called in the 27 SDK.
>
> **What would resolve it:** the "Discover Apple-Hosted Background Assets" transcript (WWDC25),
> the current `developer.apple.com/documentation/backgroundassets` reference, and — decisively —
> any Apple sample project that ships a model this way. Apple's sample-code index for `coreai`
> currently returns **zero projects** (✅ VERIFIED, `notes/CORRECTIONS-PENDING.md:245`), so this is
> not an oversight in our research; the sample does not exist yet.
>
> **SAFE DEFAULT:** build your feature against a **delivery protocol you own** (§3.4), implement it
> first with plain `URLSession` background downloads, and swap in Background Assets behind that
> protocol once you have read the current documentation. Your Core AI code does not change either
> way — the only thing Core AI needs is a local file URL.

That gap is real and this guide will not paper over it. What follows is what *can* be verified.

### 3.3 The Background Assets fragments we can verify

These come from the **iOS 26 custom-adapter** era, when Background Assets was the documented
delivery mechanism for `.fmadapter` packs. Adapters themselves are discontinued in OS 27 — two
independent Apple confirmations, quoted in §3.1 and in
`notes/forums/forum-pain-points.md:249-257` — but the *Background Assets* plumbing they exercised
is the same framework.

**Apple staff, thread 829108** (✅ VERIFIED, `notes/forums/forum-pain-points.md:267-272`):

> "Based on the code in the screenshots that you posted, it looks like you're missing a call to
> `AssetPackManager.ensureLocalAvailability(of:requireLatestVersion:)`. **When you set an asset
> pack's download policy to "on demand", you're telling the system that it shouldn't download the
> asset pack automatically.** `SystemLanguageModel.Adapter(name:)` expects that the asset pack
> already be downloaded before you call it. To fix the issue here, call
> `ensureLocalAvailability(of:requireLatestVersion:)` and wait for it to return successfully before
> constructing an `Adapter` instance."

Three durable facts in that one answer:

1. **`AssetPackManager.ensureLocalAvailability(of:requireLatestVersion:)` exists** and is the call
   that materialises a pack you have declared but not downloaded.
2. **"on demand" is a per-pack download policy** meaning *do not fetch this automatically*. That is
   precisely the policy an opt-in feature wants — it is the framework-level expression of §2's
   button.
3. **You must wait for it to succeed before consuming the asset.** The failure mode of not waiting
   is a missing-asset error at the consumption site, far from the cause.

**Community-reported, from a developer's write-up of a working TestFlight pipeline**
(`notes/forums/forum-pain-points.md:1190-1215`; attribute as **community-reported**, iOS 26 adapter
context, not an Apple statement):

```xml
<!-- Info.plist keys reported for an Apple-hosted managed asset pack -->
<key>BAHasManagedAssetPacks</key><true/>
<key>BAUsesAppleHosting</key><true/>
<key>BAAppGroupID</key><string>group.com.example.shared</string>
```

with an extension of type `StoreDownloaderExtension`, and a status stream reported as:

```swift prelude:guide-context
// Community-reported shape, iOS 26 adapter pipeline. NOT verified for Core AI in 27.
for await status in AssetPackManager.shared.statusUpdates(forAssetPackWithID: packID) {
    // reported to fire .began / .downloading(progress) / .finished
}
```

> ⚠️ **Do not copy those keys into a 27 project on this guide's authority.** They are one
> developer's report of one working configuration in the *previous* OS cycle, for a feature Apple
> has since removed. They are reproduced here because they tell you the *shape* of the
> configuration — a managed pack, Apple hosting, an app group, a store downloader extension, and an
> `AsyncSequence` of status updates — which is enough to know what to look for in the current
> documentation.

The same report contains a genuinely useful warning about the packaging step: the generated
manifest had `"onDemand": null`, which **Transporter rejected with ITMS-91140**, and the workaround
was to unpack the `.aar`, rewrite it to `"onDemand": {}`, and repack. Community-reported,
`notes/forums/forum-pain-points.md:1192-1194`. If you hit an ITMS rejection on an asset-pack upload,
that is where to look first.

> 🔴 **GAP — the packaging CLI.** The only packaging subcommand attested anywhere in our corpus is
> **`xcrun ba-package foundation-models package --adapter-path <name>.fmadapter --asset-pack-id
> <id>`** (`notes/transcripts/fm-core.md:2129`), which is adapter-specific and therefore dead in 27.
> **We have no evidence of a Core AI equivalent.** Whether models are packaged with a different
> `ba-package` subcommand, with a generic one, or entirely through Xcode is unverified. Resolving
> it needs `xcrun ba-package --help` on a machine with Xcode 27. One adjacent toolchain
> observation, reported for completeness rather than as an answer: `coreai-build` (which ships in
> the optional Metal Toolchain component — resolved 2026-07-31, §4.2) has a **`package`**
> subcommand, *"Packages a source model to produce a model asset"*, taking `.aimodel` or
> `.aimodelc` input and `--platform`/`--min-deployment-version`/`--output`
> (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) — that is model-asset packaging, not
> evidenced as a Background Assets packaging path.

### 3.4 The delivery protocol: keep Core AI independent of the transport

Given §3.2, the responsible architecture is to put a seam between "how bytes arrive" and "what Core
AI does with them." This costs about forty lines and it is what lets you adopt Background Assets
later — or run a plain `URLSession` in a TestFlight build and Background Assets in production —
without touching any specialization code.

The insight that makes this cheap: **Core AI asks for nothing but a local file URL.** Both
`AIModel(contentsOf:options:)` and `AIModel.specialize(contentsOf:...)` take a `URL` whose
documented type is *"The URL of a `.aimodel` or `.aimodelc` file"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:133`). There is no Core AI download API, no Core AI asset type, no
Core AI hosting integration. The seam is already there in the framework's design.

```swift illustrative
import Foundation

/// The only thing the rest of the app knows about model delivery.
///
/// Implementations: `BackgroundAssetsDelivery` (production),
/// `URLSessionDelivery` (TestFlight / simulator), `BundledDelivery` (tests),
/// `SideloadDelivery` (device-lab builds — see §4.7).
protocol ModelDelivery: Sendable {

    /// The asset this delivery is responsible for, including the architecture
    /// suffix if the artifact is AOT-compiled. See §4.3.
    var assetName: String { get }

    /// The version of the asset the app currently expects. Compared against the
    /// version on disk to decide whether an update is needed. See §7.
    var expectedVersion: String { get }

    /// Non-blocking, no I/O beyond a stat: the local URL if a complete copy of
    /// `assetName` at `expectedVersion` is already present. `nil` otherwise.
    func localURLIfPresent() -> URL?

    /// Downloads or otherwise materialises the asset and returns its local URL.
    /// `onProgress` receives 0...1, or `nil` when the total size is unknown.
    /// Must be safe to call when the asset is already present (returns fast).
    /// Implementations map transport, capacity, and staging errors to
    /// `ModelDeliveryFailure`; callers reserve specialization errors for Core AI.
    func fetch(onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL

    /// Removes the local copy. Does NOT touch the Core AI cache — that is the
    /// caller's job and the ordering matters (§7.3).
    func removeLocalCopy() throws
}
```

A `URLSession`-backed implementation you can ship today, with no unverified API in it:

```swift prelude:guide-context
import Foundation

/// A delivery implementation with zero Background Assets dependency.
/// Use this to build and test the feature while the BA pipeline is being set up,
/// and in any build (simulator, some CI) where BA is unavailable.
final class URLSessionDelivery: NSObject, ModelDelivery, @unchecked Sendable {

    let assetName: String
    let expectedVersion: String
    /// Conservative free-space requirement from the asset manifest, including
    /// staging and operational headroom rather than only compressed bytes.
    let requiredFreeBytes: Int64
    private let remoteBase: URL
    private let container: URL

    init(assetName: String,
         expectedVersion: String,
         requiredFreeBytes: Int64,
         remoteBase: URL) throws {
        precondition(requiredFreeBytes >= 0)
        self.assetName = assetName
        self.expectedVersion = expectedVersion
        self.requiredFreeBytes = requiredFreeBytes
        self.remoteBase = remoteBase
        // Application Support, NOT Documents: models are re-downloadable, so they
        // should not appear in the user's Files.app or be backed up.
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.container = support
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(expectedVersion, isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        // Models are re-downloadable. Excluding them from backup is required by
        // the iOS Data Storage Guidelines and keeps a 2 GB model out of iCloud.
        var mutable = container
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    func localURLIfPresent() -> URL? {
        let candidate = container.appendingPathComponent(assetName)
        // A directory that exists is not necessarily a complete download. The
        // sentinel file is written last, after the atomic move, so its presence
        // is the completion signal.
        let sentinel = container.appendingPathComponent(".complete-\(assetName)")
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return nil }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func fetch(onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        do {
            if let present = localURLIfPresent() { return present }
            let capacity = try container.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]).volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < requiredFreeBytes {
                throw ModelDeliveryFailure.insufficientStorage(
                    requiredBytes: requiredFreeBytes,
                    availableBytes: capacity)
            }
            // Download to a staging directory, verify, then move into place atomically.
            // Real implementations fetch each file in the bundle; this sketch shows
            // the ordering that matters, not a complete transfer engine.
            let staging = container.appendingPathComponent("staging-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await downloadBundle(named: assetName,
                                     from: remoteBase,
                                     into: staging,
                                     onProgress: onProgress)

            let destination = container.appendingPathComponent(assetName)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)

            // Sentinel LAST. If the app is killed mid-move, the next launch sees no
            // sentinel and re-downloads rather than loading a half-written bundle.
            FileManager.default.createFile(
                atPath: container.appendingPathComponent(".complete-\(assetName)").path,
                contents: Data())
            return destination
        } catch let failure as ModelDeliveryFailure {
            throw failure
        } catch let error as URLError {
            throw ModelDeliveryFailure.network(error.localizedDescription)
        } catch {
            throw ModelDeliveryFailure.fileSystem(error.localizedDescription)
        }
    }

    func removeLocalCopy() throws {
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent(".complete-\(assetName)"))
        try FileManager.default.removeItem(
            at: container.appendingPathComponent(assetName))
    }

    private func downloadBundle(named: String,
                                from base: URL,
                                into staging: URL,
                                onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        // Left to the reader: a background URLSession, a file manifest, and
        // per-file resume. See §3.5 for the two traps that engine must handle.
        fatalError("Implement with URLSessionConfiguration.background")
    }
}
```

The concrete delivery now performs the same phase-specific mapping it advertises: its manifest
supplies a conservative free-space requirement, and Foundation's volume-capacity value makes the
`.insufficientStorage` path reachable before transfer begins.[^storage-preflight] Because the
capacity key is a required-reason API, include the approved reason in the app's privacy manifest;
do not copy this preflight without that declaration.

The sentinel-file pattern in `localURLIfPresent()` deserves a note. A `.aimodel` is a directory,
so "does the path exist" is *not* "is the download complete" — a partially-transferred bundle is a
directory that exists and fails to load. Writing a zero-byte completion marker after the atomic
move converts a multi-file transfer into a single-bit commit. If you adopt Background Assets, the
framework's own completion signal replaces this; until then, you need something like it.

### 3.5 Two download traps that a production engine must handle

These are **community-measured**, from a shipping iOS app's download engine
(`noema-ios`, `BackgroundDownloadManager.swift`, 1,901 lines; notes at
`notes/repos/noema-ios.md:1633-1682`). They are not Core AI issues — they are URLSession issues that
every model-download implementation meets.

**Trap 1 — background tasks created while the app is inactive are discretionary, and
`isDiscretionary = false` is ignored for them.** The app's own source comment, quoted verbatim in
the notes:

> "`createdInBackground`: Whether the task was created while the app was not active (**such
> background-session tasks are discretionary — the system ignores `isDiscretionary=false` for
> them**)."

Community-measured, `notes/repos/noema-ios.md:1669-1670`. Consequence: a download you start from a
background refresh, or one that you *create* after the app resigns active, may sit for hours. The
mitigation in that codebase is to run two sessions — a foreground `URLSessionConfiguration.default`
and a background one — and **migrate live tasks between them on lifecycle transitions**.

**Trap 2 — the two resume kinds are not interchangeable and mixing them corrupts your progress
bar.** Again from the same engine:

- **Range-header resume** → the offset is **additive**: `totalBytesWritten + resumeOffset`.
- **Resume-data resume** → the totals are **already absolute**; adding an offset freezes visible
  progress.

Community-measured, `notes/repos/noema-ios.md:1674-1676`. The codebase keeps `resumedAtOffset` as
display-only and notes it *"lets us detect a server that ignored the resume (HTTP 200)"* — which is
itself a good check: a server that answers a `Range` request with 200 instead of 206 has silently
restarted your 1.8 GB transfer.

A third, smaller one worth knowing if you use `BGContinuedProcessingTask` (iOS 26+) to keep a
transfer alive: **`BGTaskScheduler.register` crashes on a duplicate identifier**, so a per-batch
UUID identifier plus a wildcard `BGTaskSchedulerPermittedIdentifiers` entry is the pattern that
works. Community-measured, `notes/repos/noema-ios.md:1697, 2067`. The wildcard form reported is
`arminproducts.Noema.download.continue.*`.

### 3.6 Where to put the file

One decision that is easy to get wrong and expensive to change.

- **`Application Support`** — the right default. Not user-visible, not in Files.app, and you can
  mark it `isExcludedFromBackup`. Models are re-downloadable by definition; putting a 2 GB
  re-downloadable artifact into iCloud backup is a support ticket waiting to happen.
- **`Documents`** — only if you *want* the user to see and manage the files. The community app
  `noema-ios` deliberately does this (`Documents/LocalLLMModels/<owner>/<repo>/…` with
  `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, `notes/repos/noema-ios.md:1737`)
  because its whole premise is user-managed models. That is a product decision, not a default.
- **`Caches`** — do not. The system may evict it under storage pressure at a moment of its
  choosing, and you will then be holding a Core AI cache entry whose source asset has vanished,
  which is one of the documented purge conditions (§11.2). You would be creating the exact race
  the `.persistent` policy exists to avoid.

One more, from the same community codebase and easy to miss: **the sandbox container path changes
across installs**, so absolute URLs persisted in `UserDefaults` go stale. That app carries an
explicit `rehomeIfMissing()` recovery step for it (`notes/repos/noema-ios.md:1739`). Persist paths
*relative to* a directory you resolve at launch, never absolute.

---

## 4. Per-architecture variants

### 4.1 Why there is more than one artifact

Specialization has two phases, and ahead-of-time compilation moves the expensive one to your Mac.
The clearest statement is from session 326:

> "**During specialization the model goes through two main transformations. First it goes through a
> core set of compilation steps. Second, executable artifacts are generated. These artifacts are
> tied to the device and OS version they were generated on. Of these two steps, compilation is the
> most expensive and takes the most amount of time.**
> The Core AI toolchain lets me do **some of that compilation ahead-of-time on my development
> machine, producing a compiled version of the model**. While that compiled model **still needs to
> be specialized for the specific user's device**, there is now much less work to do and finishes
> significantly faster."

✅ VERIFIED — WWDC26 session 326, 155-170, via `notes/transcripts/coreai-intro.md:1694-1695`.

Apple's documentation says the same thing with the artifact names attached:

> "Ahead-of-time compilation converts your `.aimodel` model file into `.aimodelc` assets, **one for
> each device architecture**. At runtime, your app picks the asset that matches the current
> device's architecture, and Core AI generates the executable code on device without repeating the
> compilation step."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1419`).

And, crucially, that AOT is a reduction and not an elimination:

> "**Even with ahead-of-time compilation, the compiled asset still requires some specialization on
> the device.** The amount of compilation that remains depends on the model and the compute units
> it uses."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1466`).

Compare with `AIModel.specialize(...)`, which people confuse with AOT constantly. Apple draws the
line explicitly:

> "The `specialize` method **differs from ahead-of-time compilation**. With ahead-of-time
> compilation, most of the heavy computation happens on your Mac at build time, so on-device
> specialization finishes faster. With `specialize`, **the full specialization process runs on the
> person's device. You are controlling *when* specialization happens, not *reducing the work it
> does*.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1303`).

So: `specialize()` moves the cost in *time*. `coreai-build` reduces the cost in *work*. They
compose, and a well-built feature uses both — AOT to shrink the work, the first-run screen plus
`specialize()` to schedule what remains.

### 4.2 The command

```shell
% xcrun coreai-build compile MyModel.aimodel \
    --platform iOS \
    --min-deployment-version 27.0 \
    --output compiled/
```

✅ VERIFIED verbatim — Apple's *Compiling Core AI models ahead of time* article
(`notes/web/apple-docs-coreai.md:1436`).

Flags Apple documents in prose:

| Token | Meaning | Evidence |
|---|---|---|
| `compile` | the subcommand | ✅ Apple docs |
| `<input>.aimodel` | positional input | ✅ Apple docs |
| `--platform iOS` | target platform | ✅ Apple docs |
| `--min-deployment-version 27.0` | minimum OS the artifacts must run on | ✅ Apple docs |
| `--output compiled/` | output directory | ✅ Apple docs |
| `--preferred-compute` | *"By default, Core AI selects the compute units that deliver the best performance for the model and platform. To override, pass `--preferred-compute`."* | ✅ Apple docs |

Apple then says, verbatim: *"For the available values, the minimum deployment version, **the target
architecture**, and other options, run `coreai-build compile --help`."* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1448`). So Apple's own prose confirms an architecture-selection
flag exists while never printing it or any of its values.

A **community-run `--help`**, dated 2026-06-10, fills that in
(`notes/repos/john-rocky-models.md:1122-1127`; community-measured, one machine, one beta):

```
coreai-build compile <input.aimodel> [--output <dir>]
    [--platform iOS|macOS|watchOS|visionOS|tvOS ...]
    [--min-deployment-version 27.0]
    [--preferred-compute gpu|neural-engine|none]
    [--architecture <arch> ...]
    [--expect-frequent-reshapes]
```

Two flags there are not in Apple's prose at all: **`--architecture`** (repeatable) and
**`--expect-frequent-reshapes`**. Both are corroborated by independent use in GitHub issues on
`apple/coreai-models`:

```bash
# From issue #55 (author john-rocky), macOS 27.0 26A5353q, M4 Max
xcrun coreai-build compile exports/qwen3_0_6b_ios_pure4bit/qwen3_0_6b_ios_pure4bit.aimodel \
  --platform iOS --preferred-compute neural-engine --architecture h18p --output /tmp/ok
```

```bash
# From issue #77 (author Bersaelor), iPad Pro M4, iPadOS 27 beta — a 4-component Flux2 bundle
for m in VAEEncoder_half VAEDecoder_half TextEncoder Transformer_512; do
  xcrun coreai-build compile "$SRC/${m}.aimodel" \
    --platform iOS --architecture h16g --preferred-compute gpu \
    --output "$DST/${m}.aimodelc"
done
```

Both ✅ VERIFIED as *quoted commands from public issue threads*
(`notes/repos/issues-coreai-stack.md:884-885, 1180-1184`) — verified that these commands were run
and reported, **not** verified as Apple-sanctioned usage.

> ✅ **VERIFIED — upgraded from 🟡 RECONSTRUCTED on 2026-07-31.** `--architecture` (repeatable)
> and `--expect-frequent-reshapes` are both real: `xcrun coreai-build compile --help` has now been
> run against the shipped tool (`coreai-build 3600.79.1`) and the community synopsis above is
> confirmed flag-for-flag, including `--preferred-compute {gpu, neural-engine, none}` (default
> `none`) and the `--platform` default of macOS. Full capture:
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`. The 2026-07-29 finding that made this
> unverifiable — `xcrun --find coreai-build` failing and no `coreai*` file in
> `Xcode-beta.app` — accurately described an installation without the optional component:
> **the wrapper ships in the Metal
> Toolchain component** (`xcodebuild -downloadComponent MetalToolchain`), resolving via
> `xcrun --no-cache --find coreai-build` to
> `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<hash>/Metal.xctoolchain/usr/bin/`.
> Build scripts and CI must install that component, or they reproduce the "absent" state.

**Also note the compiler binary.** `xcrun coreai-build compile` is the verb; inside the app bundle
there is only `aimodelc`, living at `Xcode-beta.app/.../usr/bin/aimodelc` — community-reported
(`notes/repos/john-rocky-models.md:1117-1120`) and **toolchain-confirmed 2026-07-29**: the stub
accepts command types `package` and `compile` only, requires `--output`, implements no `--help`,
and its binary embeds *"Please use 'xcrun coreai-build' instead"* — pointing (we now know) at the
tool in the separate Metal Toolchain component. Useful only for debugging a toolchain
installation.

### 4.3 Output naming and the runtime lookup

Apple documents the naming convention precisely, and it is the contract between your build script
and your app:

> "`coreai-build` outputs one compiled `.aimodelc` file per device architecture, using the input
> model's filename as the prefix. For example, compiling `MyModel.aimodel` produces files named
> **`MyModel.<arch>.aimodelc`**, where `<arch>` is the device architecture identifier returned by
> `deviceArchitectureName` at runtime. **Each compiled `.aimodelc` works on any OS version at or
> above the minimum deployment version you pass to `coreai-build`.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1453`).

The runtime half is two lines, and Apple prints them verbatim:

```swift compile:27 imports:CoreAI
let arch = AIModel.deviceArchitectureName
let assetName = "MyModel.\(arch).aimodelc"
```

✅ VERIFIED verbatim — Apple's AOT article (`notes/web/apple-docs-coreai.md:1458-1461`). The
property is documented as:

```swift illustrative
static var deviceArchitectureName: String { get }
```

✅ VERIFIED (`notes/web/apple-docs-coreai.md:128`), with the discussion: *"When compiling model
assets ahead of time with `xcrun coreai-build compile`, the toolchain produces artifacts for
specific device architectures. Use this property to discover which compiled asset matches the
current device."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:156`).

That is Carina's "small amount of code" from session 326:

> "**I did this with my model and created a background asset for each compiled model. There is a
> small amount of code I add to my app to detect the architecture of the device it's running on and
> then request the appropriate asset based on that.**"

✅ VERIFIED — session 326, 155-170 (`notes/transcripts/coreai-intro.md:1697`).

And the load call does not change at all:

> "To load the downloaded `.aimodelc` asset, use `init(contentsOf:options:)`. **This is the same API
> you use to load `.aimodel` files, so you don't need to change your loading code when you adopt
> ahead-of-time compilation.** Use the default options, or specify options that match the compute
> units you used at compile time."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1463`). Note the last clause — "specify options that
match the compute units you used at compile time" is not decorative. §5.4 and §9 are both about
what happens when they diverge.

Wiring it into the delivery protocol from §3.4:

```swift compile:27
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelArtifact {

    /// The asset name this device should request.
    ///
    /// Apple's documented convention is `<base>.<arch>.aimodelc`, where `<arch>`
    /// is exactly `AIModel.deviceArchitectureName`.
    static func compiledAssetName(base: String) -> String {
        "\(base).\(AIModel.deviceArchitectureName).aimodelc"
    }

    /// The portable fallback, for devices with no compiled variant (see §4.6) or
    /// when the compiled variant fails to load (see §5.5).
    static func portableAssetName(base: String) -> String {
        "\(base).aimodel"
    }
}
```

Availability gating, because `deviceArchitectureName` is 27.0-only and your app is probably not:

```swift compile:27 imports:CoreAI
enum DeviceArchitecture {
    /// Empty string when Core AI is unavailable — deliberately, so that a
    /// name-contains check against it simply never matches rather than crashing.
    static var current: String {
        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return AIModel.deviceArchitectureName
        }
        #endif
        return ""
    }
}
```

That exact shape — including the empty-string fallback and the `#if canImport(CoreAI)` guard so the
code still compiles on an Xcode 26 toolchain — is taken from the community app `noema-ios`
(`CoreAIDeviceArchitecture`, `notes/repos/noema-ios.md:627-637`; community source). It uses the
result as a **ranking key** rather than an exact match: when several bundles are present it prefers
an `.aimodelc` whose filename *contains* `AIModel.deviceArchitectureName`, falling back through a
family ranking. That is a good pattern for an app that accepts sideloaded models; for an app that
controls its own hosting, an exact name is better because a miss should be an error, not a silent
downgrade.

### 4.4 ⚠️ Architecture codes track the DEVICE IDENTIFIER, not the marketing name

This is the single most surprising fact in this section, and getting it wrong produces §5's silent
failure.

The `--architecture` values are lowercase `h`-prefixed codes. They follow the **hardware
device-identifier major version** — the `iPhone18,1` / `Mac16,5` string — **not** the marketing
name. Community-measured and device-validated on 2026-06-10
(`notes/repos/john-rocky-models.md:1156-1168`):

> - **iPhone 17 Pro = `iPhone18,1` → `h18p`.** An `h17p` `.aimodelc` pushed to it fails to load
>   with `invalidCompiledModel`; the same model compiled `--architecture h18p` loads and runs.
> - **M4 Max Mac = `Mac16,x` → `h16c`.** *"Of all 20 macOS archs, only `h16c` loads in the Python
>   runtime on an M4 Max; h17\*/h16g/h16s all raise RuntimeError."*

Read the first bullet slowly. The device *marketed* as iPhone **17** Pro reports device identifier
`iPhone**18**,1` and takes architecture code `h**18**p`. Every naive mapping — "17 Pro means
h17p" — is wrong, and the archive that reports this **explicitly corrects its own earlier note**
which had guessed `h17p` by name-matching. The correction is dated and attributed in the source,
which is why it is worth citing as a cautionary tale rather than just a fact.

The codes observed in the wild, with what they were reported to correspond to:

| Code | Reported device class | Source | Confidence |
|---|---|---|---|
| `h18p` | iPhone 17 Pro (`iPhone18,1`) | device-validated load + run | community-measured, high |
| `h16g` | iPad M4-class | used successfully in a Flux2 compile on iPad Pro M4 | community-reported |
| `h16s` | M4 Max Mac | used in a compile that then **failed to load** (see below) | community-reported, contested |
| `h16c` | M4 Max Mac (`Mac16,x`) | *"only `h16c` loads … on an M4 Max"* | community-measured, contested |
| `h16p` | iPhone 15 Pro (`iPhone16,1`; hardware `D83AP`) | `AIModel.deviceArchitectureName` printed by this project's physical-device probe on iOS 27 beta 5 (`24A5408d`), 2026-08-20 | ✅ project device-verified |
| `h13g` `h14g` `h15g` `h16g` `h16p` `h17g` `h17p` `h18p` | the **8 iOS archs** emitted by one `--platform iOS --preferred-compute neural-engine` run | full output listing | community-measured |
| `h13c` … `h17s` | the **20 macOS archs** emitted by one `--platform macOS` run | count + range only | community-measured |

Sources: `notes/repos/john-rocky-models.md:1161-1164, 1176-1181`;
`notes/repos/issues-coreai-stack.md:1187`.

> 🔴 **GAP — the architecture-code enumeration was incomplete, community-sourced, and internally
> contested. Narrowed 2026-07-31: the code *set* is now first-party-probed; the device mapping is
> still contested.**
>
> **Now enumerated:** probing the shipped `coreai-build` 3600.79.1's `--architecture` validation
> (it validates the code before reading the input file, with distinct diagnostics for unknown /
> valid-but-wrong-platform / accepted) yields **24 valid codes**: `h11p h11g h12p h13p h13s h13c
> h13g h14p h14s h14c h14g h15p h15s h15c h15g h16p h16s h16c h16g h17p h17s h17c h17g h18p`.
> Observed grammar: `h<generation><variant>`, `p` = phone-class (accepted for iOS/tvOS), `s`/`c` =
> Mac-class, `g` present from `h13g` up — consistent with the tier reading above, though the
> letters' meanings are still nowhere stated by Apple. At the 27.0 default target, macOS accepts
> the `s`/`c`/`g` codes (plus `h17p`), iOS the `p`/`g` codes through `h18p`; watchOS and visionOS
> accepted none of the swept codes on the probing host (macOS 26.5 — possibly missing
> device-support data). Method and full matrix:
> `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`, final section.
>
> **What is still unknown:** the authoritative complete list of `deviceArchitectureName` values
> (the compiler's accepted set is the best proxy, not a definition), most code-to-device mappings,
> and which code a given Mac actually reports. One mapping is now project-verified rather than
> community-attested: on 2026-08-20, `probes/` printed **`h16p`** on a physical iPhone 15 Pro
> (`iPhone16,1`, `D83AP`) running iOS 27 beta-5 build `24A5408d`.
>
> **The contested part is specific and worth naming.** Two community sources disagree about the M4
> Max Mac. One says `h16c` is the only code that loads there
> (`notes/repos/john-rocky-models.md:1163-1164`). A separate GitHub issue on `apple/coreai-models`
> (#27, same author, M4 Max `Mac16,9`) compiles with `--architecture h16s` and then **fails to
> load** with `AIModelError error 3` — but attributes it to a *different* cause: *"this macOS build
> cannot load **any** precompiled `.aimodelc` for a macOS target, while the same Core AI runtime
> loads AOT `.aimodelc` fine on **iOS** (h18p bundles run on iPhone 17 Pro)"*
> (`notes/repos/issues-coreai-stack.md:946-957`). Both explanations fit the same observation. We
> cannot separate "wrong arch code" from "macOS AOT load is broken on this beta."
>
> **What would resolve it:** printing `AIModel.deviceArchitectureName` on one device of each family
> — a two-line app. That is the *only* authoritative source, because the property is defined as the
> thing that matches.
>
> **SAFE DEFAULT:** never hardcode an architecture code anywhere in your app. Build the asset name
> from `AIModel.deviceArchitectureName` at runtime, exactly as Apple's snippet does. On the build
> side, either omit `--architecture` and ship every emitted variant (expensive — see §4.5), or
> derive your target list by running a one-screen diagnostic build on each device in your test
> matrix and reading the property. **Always ship the portable `.aimodel` as a fallback** so an
> unrecognised architecture degrades to slow-but-working rather than broken.

### 4.5 The cost of emitting every architecture

Omitting `--architecture` is not free. Community-measured, on a vision-language model export:

> **"Always pass `--architecture h18p`** — *omitting it emits all ~20 Mac GPU archs (**34 GB**)."*

Community-measured, `notes/repos/john-rocky-models.md:3570`. Thirty-four gigabytes of build output
from one model.

The per-artifact multiplier, same archive, iPhone 17 Pro target:

> *"The result (`*.h18p.aimodelc`, **~2× the `.aimodel` size**) embeds the precompiled graph."*

Community-measured, `notes/repos/john-rocky-models.md:879-880`.

So the storage arithmetic for a hosted, per-architecture rollout is roughly:

```
hosting footprint  ≈  2 × (source .aimodel size) × (number of architectures shipped)
device footprint   ≈  2 × (source .aimodel size)     ← one variant only
```

The second line is the one that matters and it is the reason Apple's recommendation is *host
remotely, download one*: **"each device only uses one of them"** ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1456`). Bundling all variants into the app would multiply the very
problem §1 is about.

The internal structure of an emitted variant, community-reported:
`base.<arch>.aimodelc` containing `main-<arch>.mlirb` + `main-<arch>-delegates`
(`notes/repos/john-rocky-models.md:1128-1129`). One nice corroborating detail from the same source:
a model containing a **custom Metal kernel** (`TorchMetalKernel`) survives AOT — the `.aimodelc`'s
`specialized_model_*.mpsgraph` contains the full `[[kernel]]` MSL signature plus compiled MTLB in
`resources.bin`, and *"the compiled asset's outputs are **bit-identical** to the source
`.aimodel`."* Community-measured, `notes/repos/john-rocky-models.md:1169-1172`.

### 4.6 When to bother with AOT at all

Three thresholds, in decreasing order of confidence.

**Apple's threshold: whenever the device supports it.** AOT is only emitted for
Apple-Intelligence-capable hardware (A17 Pro+, M1+, M2 Vision Pro) — ✅ VERIFIED, §version-floor
above. Everything older takes the portable path regardless of what you do. So AOT is never a
complete strategy; it is an optimisation for the top of your device matrix and you always need the
`.aimodel` fallback.

**Community threshold, by model size** (community-measured, one engineer, iPhone 17 Pro / iOS 27,
`notes/repos/john-rocky-models.md:871-872`):

> *"On-device JIT specialization of a big static graph stalls or gets killed; roughly **≥ 1 GB
> means AOT**, ≤ ~50 MB JITs fine, in between try it."*

**Community threshold, by failure mode.** The same archive documents a 4B-class decoder
(FastContext-1.0-4B / Qwen3-4B) on iPhone 17 Pro / iOS 27 where every non-AOT path failed
(`notes/repos/john-rocky-models.md:1101-1113`):

| Attempt | Failure |
|---|---|
| macOS-tagged IR on iOS | no iOS delegates to load → `NSPOSIXErrorDomain Code=2` |
| iOS-tagged palettized IR, on-device GPU specialization | *"exhausts the device's scratch disk mid-compile → `LLVM ERROR: No space left on device`"* |
| iOS ANE bundle | static-loads (31 ANE regions, ~518 s cold) but warmup **inference** dies: `com.apple.appleneuralengine` / `ANECompilerService` **`Code=4097`** |
| **GPU AOT `.aimodelc`** (`--preferred-compute gpu --architecture h18p`) | ✅ the only working on-device path |

Conclusion in that source: *"4B-class GPU bundles **must** be AOT-compiled per device class."*
Community-measured; one device; beta OS. But note the *shape* of the failures — "no space left on
device" and a 518-second cold load are not things you discover in a simulator.

**The measured win, when it works** (community-measured, GPU monolith, post cache-wipe true-cold,
`notes/repos/john-rocky-models.md:1194-1197`):

> **`.aimodelc` 4.9 s vs `.aimodel` 19.2 s true-cold specialize (~4×); warm 0.0 s both** (the OS
> cache serves `.aimodelc` too).

Roughly a 4× reduction in first-load time — not the elimination that "ahead-of-time compilation"
suggests, which is exactly what Apple's *"still requires some specialization on the device"* caveat
predicts.

**And where it does not work.** The same archive reports that AOT compilation of a set of
host-cache *chunk* graphs makes `coreai-build` itself SIGSEGV (host-side
`ANECompilerOffline::~ANECompilerOffline → objc_release` inside MPSGraph's `anePreCompileBinary`,
~0.9 s in, all 6 chunks, both architectures), while the monolith from the same authoring compiles
fine — diagnosed as *"beta compiler bug, size/shape-correlated"*
(`notes/repos/john-rocky-models.md:1189-1193`). A near-identical crash signature is the subject of
open issue #55 on `apple/coreai-models`, where the maintainer's response was *"We will file an
internal report and investigate this"* (`notes/repos/issues-coreai-stack.md:920-921`). If
`coreai-build` exits 139 after several minutes at 100% CPU with no diagnostic, that is this bug and
not your model.

### 4.7 A build script

Putting §4.2–§4.5 together. This emits exactly the variants you intend, names them the way the
runtime expects, and records what it did so §7's versioning has something to read.

```bash
#!/usr/bin/env bash
# build-model-variants.sh — emit per-architecture .aimodelc plus the portable fallback.
#
# Requires: Xcode 27 with the Metal Toolchain
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

MODEL="${1:?usage: $0 <MyModel.aimodel> <version>}"
VERSION="${2:?usage: $0 <MyModel.aimodel> <version>}"
BASE="$(basename "$MODEL" .aimodel)"
OUT="dist/${VERSION}"

# Architectures to emit. DERIVE THESE by printing AIModel.deviceArchitectureName
# on each device in your test matrix — do not copy them from a blog post, and do
# not infer them from marketing names (iPhone 17 Pro is h18p, not h17p).
IOS_ARCHS=( h18p )          # extend after you have measured each device
MIN_VERSION="27.0"

mkdir -p "$OUT"

# 1. The portable fallback. Always ship it: pre-A17-Pro devices get no compiled
#    variant at all, and §5.5's recovery path needs somewhere to fall back to.
cp -R "$MODEL" "$OUT/${BASE}.aimodel"

# 2. One compiled variant per architecture.
for arch in "${IOS_ARCHS[@]}"; do
  echo "==> compiling ${BASE} for ${arch}"
  xcrun coreai-build compile "$MODEL" \
    --platform iOS \
    --min-deployment-version "$MIN_VERSION" \
    --architecture "$arch" \
    --preferred-compute gpu \
    --output "$OUT"
  # `coreai-build` names the output itself: <base>.<arch>.aimodelc
  if [[ ! -d "$OUT/${BASE}.${arch}.aimodelc" ]]; then
    echo "FATAL: expected $OUT/${BASE}.${arch}.aimodelc — naming convention changed?" >&2
    exit 1
  fi
done

# 3. A manifest the app can read to decide whether it needs an update (§7.2).
{
  echo "{"
  echo "  \"base\": \"${BASE}\","
  echo "  \"version\": \"${VERSION}\","
  echo "  \"minDeploymentVersion\": \"${MIN_VERSION}\","
  printf '  "architectures": ['
  printf '"%s"' "${IOS_ARCHS[0]}"
  for arch in "${IOS_ARCHS[@]:1}"; do printf ', "%s"' "$arch"; done
  echo "]"
  echo "}"
} > "$OUT/manifest.json"

echo "==> done. Contents of $OUT:"
du -sh "$OUT"/* | sort -h
```

Note the explicit `if [[ ! -d ... ]]` check after each compile. That is not defensive
programming for its own sake — it is the *only* thing in the whole script that verifies
`coreai-build` did what you asked, and §5 explains why the exit code will not tell you.

---

## 5. ⚠️ SILENT FAILURE: a green compile that the device rejects

### 5.1 The defect

> ⚠️ **SILENT FAILURE.** **`xcrun coreai-build compile` exits 0 for architectures the device will
> reject.** A successful compile does not validate the architecture choice — only a device load
> does. The failure surfaces as `invalidCompiledModel` in a user's hands, after a green CI build.

The finding, community-measured and device-validated 2026-06-10
(`notes/repos/john-rocky-models.md:1165-1167`, restated at `:4459-4460`):

> **"`coreai-build compile` EXITs 0 for ANY requested arch"** — *"a successful compile does NOT
> validate the arch choice; only a device load does."*

And the observed consequence, same source (`notes/repos/john-rocky-models.md:1161-1162`):

> "An `h17p` `.aimodelc` pushed to it fails to load with `invalidCompiledModel`; the same model
> compiled `--architecture h18p` loads and runs."

### 5.2 Why this is worse than an ordinary build failure

Walk the timeline of a plausible team.

1. An engineer reads "iPhone 17 Pro" in the test plan and writes `--architecture h17p` in the build
   script. The name matches. It is the obvious choice.
2. `coreai-build` **exits 0** and writes `MyModel.h17p.aimodelc`. The script's own existence check
   passes, because the file it asked for is there.
3. CI is green. The artifact uploads to your hosting. The manifest lists `h17p`.
4. Every simulator test passes, because the simulator never loads a compiled variant.
5. Every device test on a *non*-iPhone-17-Pro passes, because those devices fall through to a
   different variant or to the portable `.aimodel`.
6. Ship.
7. On iPhone 17 Pro — which reports `deviceArchitectureName == "h18p"` — the asset lookup for
   `MyModel.h18p.aimodelc` **finds nothing**, or, if you built a fuzzier lookup, finds `h17p` and
   fails to load it.

Every gate in that pipeline is a gate on the *compiler*, and the compiler is not the thing that
knows. The knowledge lives in one place: `AIModel.deviceArchitectureName`, read on the device.

There is a second, meaner variant of the same failure. If you build the asset name at runtime from
`deviceArchitectureName` — as Apple's snippet does and as this guide recommends — then a wrong
`--architecture` at build time does not produce a load error at all. It produces a **404 from your
asset host**, which your code will classify as a network failure and retry forever. The user sees
"Download failed. Check your connection." on a perfectly good connection. That is arguably the
worst of the three outcomes, because the error message actively points away from the cause.

### 5.3 What the error looks like

Two different names for the same event, at two different layers. Know both, because you will see
whichever one your stack surfaces.

**At the Core AI framework layer**, from a raw `AIModel.load`
(`notes/repos/issues-coreai-stack.md:952-954`):

```
CoreAIDelegates.AIModelError error 3
```

**At the `apple/coreai-models` package layer**, wrapped by `LanguageBundle` / the `llm-runner`
tool (same source):

```
invalidCompiledModel
```

> ✅ **RESOLVED (was a GAP) — `AIModelError` is confirmed non-public, and the throws are untyped.**
> The SDK interface dump was captured 2026-07-29 from Xcode build `27A5228h` and recaptured
> 2026-08-20 from beta 5 build `27A5237l` (`notes/sdk-interfaces/`). `CoreAIDelegates-27.0-macos.swiftinterface` declares
> `AIModel.init(contentsOf:options:)` and `specialize(…)` as plain untyped `async throws`
> (✅ **SDK-verified** — `:22-26`) and the cache methods as untyped `throws` (`:33-43`); **no
> `AIModelError` appears anywhere in the public interface** — it is internal, surfacing only via
> `NSError` bridging as `CoreAIDelegates.AIModelError error 3`. The only public error type in the
> whole Core AI surface is `AssetError`, with five `Kind` cases (`unsupportedVersion(String)`,
> `invalidFeatureType(String)`, `corruptedMetadata`, `invalidName`, `duplicateName`) — ✅
> **SDK-verified** (`CoreAIAsset-27.0-macos.swiftinterface:230-247`), matching the doc pages. The
> meaning of code 3 remains open in the community issue archive
> (`notes/repos/issues-coreai-stack.md:1462`).
>
> **PRACTICE:** do not pattern-match on `AIModelError` cases — in the macOS 27.0 beta SDK the type
> is not public and cannot be named. But the converse matters just as much: an **untyped** throw
> does not prove that the compiled variant is corrupt or incompatible. Preserve task cancellation,
> log the dynamic type plus `NSError` domain/code, and **rethrow an unclassified error**. Fall back
> to the portable asset only after an evidence-backed classifier identifies an integrity or
> compatibility failure; that classifier must default to `false`. Leave the cache intact on the
> fallback path too — deletion belongs in a separate bounded repair test after the cache itself has
> been isolated as the cause.
> Full treatment of the public error surface: Part 7, guide 7.1 §13.[^untyped-fallback-policy]

Note also that `invalidCompiledModel` is a **package-level** name from `apple/coreai-models`, not a
Core AI framework symbol. If you are not using that package you will never see the string. Do not
write `catch CoreAIError.invalidCompiledModel` — no such thing exists in the framework.

### 5.4 A second way a compiled asset fails to load, with the same shape

Worth knowing here because it presents identically — a green compile, a device-side death — and its
cause is completely different.

> ⚠️ **`SpecializationOptions.expectFrequentReshapes = true` on a fixed-shape graph kills an AOT
> bundle.** Community-measured, device-validated 2026-07-23, iPhone 17 Pro
> (`notes/repos/john-rocky-models.md:1132-1154`):
>
> *"The hint is not free insurance — it is a request for a reshape-tolerant specialization."* Ask
> for it at load time on an all-static graph and the runtime **stops using the AOT specialization
> and compiles on device**, which segfaults inside the MPSGraph AICode compiler:
>
> ```
> EXC_BAD_ACCESS (SIGSEGV) … MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:
>   → Compiler_coreAI.compile(moduleBytecode:to:with:) → libODIECompiler … CompileForDelegates
> ```
>
> *"No error string, no partial output — the app just dies at `AIModel(contentsOf:options:)`."*

Three details from that report make it directly actionable:

- The specific model (VibeVoice, 5 fixed-shape graphs) went from **SIGSEGV on the first graph** with
  `expectFrequentReshapes = true` to **all 6 loads in 2.6 s** with `= false`.
- **Compiling with `--expect-frequent-reshapes` does NOT make the runtime hint safe.** Both the
  plain and the reshape-hinted `.aimodelc` crashed when the *runtime* asked for the hint. **It is
  the load-time option that matters.**
- The rule the archive lands on: set it **only** where shapes genuinely change (dynamic query
  length, bucketed prefill). Static decode (`S=1`) and fixed-T graphs must load **without** it.

For the API itself: `expectFrequentReshapes` is a `var` on `SpecializationOptions`, and Apple's
documentation for it consists of exactly one abstract line — *"Setting to allow more optimal
specialization if the model performs frequent reshapes based on usage"* — with **no discussion
section, no documented default, and no initializer that sets it** ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1082`). It is set by mutation:

```swift prelude:guide-context
var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
options.expectFrequentReshapes = true
```

That mutation pattern is confirmed in Apple's own shipping package
(`apple/coreai-models`, `swift/Sources/CoreAIShared/Runtime/ModelStructure.swift:70-81`, quoted at
`notes/transcripts/coreai-intro.md:983-996`), where Apple picks `.neuralEngine` for
static-shape/chunked models and `.gpu` + `expectFrequentReshapes` for dynamic-shape LLMs. So the
property is real, Apple uses it, and Apple documents it in one sentence.

The connection back to §5.1: both defects mean **a compiled artifact that passed every build-time
check can be un-loadable on the target device**, and in neither case does the build tell you.

### 5.5 The mitigation: verify on device, and always keep a fallback

Three layers, cheapest first.

**Layer 1 — a device diagnostic that prints the truth.** One screen, shipped in an internal build,
run once per device family. It replaces the entire guessing game in §4.4.

```swift prelude:guide-context
import SwiftUI
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct ArchitectureDiagnosticView: View {

    private var report: [String: String] {
        [
            // THE authoritative value. Everything else is inference.
            "deviceArchitectureName": AIModel.deviceArchitectureName,
            "availableComputeUnits": ComputeUnitKind.availableKinds
                .map(String.init(describing:))
                .sorted()
                .joined(separator: ", "),
            "expectedAssetName": ModelArtifact.compiledAssetName(base: "MyModel"),
        ]
    }

    var body: some View {
        List {
            ForEach(report.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                LabeledContent(key) {
                    Text(value).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Core AI device report")
    }
}
```

`ComputeUnitKind.availableKinds` is ✅ VERIFIED — *"The compute unit kinds available on the current
device"*, a `static var` returning `Set<ComputeUnitKind>` over `.cpu` / `.gpu` / `.neuralEngine`
(`notes/web/apple-docs-coreai.md:1091-1095`). Apple's advice on it: *"Because not all devices have
the same compute units available, check what's available with `availableKinds`"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1286`).

**Layer 2 — a load smoke test in CI-on-device.** If you have a device lab, the check is: for every
architecture in your manifest, on a device that reports that architecture, actually construct an
`AIModel` and load one function. Nothing shorter proves anything. Note the community guidance on
how to measure it, which applies equally to a smoke test: run *"an env-gated headless entrypoint
… that loads the bundle, runs **1 cold + N warm** passes, computes the metric and writes a result
file"*, because *"numbers measured through a chat UI are not comparable to anything"*
(community, `notes/repos/john-rocky-models.md:885-888`).

**Layer 3 — a guarded runtime fallback.** A verified compiled-asset incompatibility can degrade to
the portable model; an unknown or transient failure remains an error instead of triggering
destructive recovery or expensive surprise work.

```swift compile:27
import CoreAI
import OSLog

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelLoader {

    private static let log = Logger(subsystem: "com.example.app", category: "coreai")

    /// Loads the compiled variant when present. Uses the portable `.aimodel`
    /// when no variant exists or a caller verifies compiled incompatibility.
    ///
    /// Keep a portable fallback: pre-A17-Pro devices get no compiled variant at
    /// all (Apple's documented AOT hardware gate). If a compiled variant exists
    /// but throws, fall back only when the caller can positively identify an
    /// integrity/compatibility failure; unknown failures are rethrown.
    static func load(
        compiled compiledURL: URL?,
        portable portableURL: URL,
        options: SpecializationOptions,
        isVerifiedCompiledIncompatibility: (any Error) -> Bool = { _ in false }
    ) async throws -> AIModel {

        if let compiledURL, FileManager.default.fileExists(atPath: compiledURL.path) {
            do {
                let model = try await AIModel(contentsOf: compiledURL, options: options)
                log.info("Loaded compiled variant \(compiledURL.lastPathComponent, privacy: .public)")
                return model
            } catch let cancellation as CancellationError {
                // A fallback is new work. Never turn task cancellation into a
                // portable-model specialization that the caller no longer wants.
                throw cancellation
            } catch {
                // `AIModelError` is not public (§5.3). Log what is observable,
                // but do not infer "corrupt cache" from an untyped throw.
                let nsError = error as NSError
                log.error("""
                    Compiled variant failed: \(compiledURL.lastPathComponent, privacy: .public) \
                    arch=\(AIModel.deviceArchitectureName, privacy: .public) \
                    domain=\(nsError.domain, privacy: .public) code=\(nsError.code)
                    """)
                // Preserve the specialization cache. This failure may be transient;
                // an untyped throw is not evidence that the entry is poisoned.
                guard isVerifiedCompiledIncompatibility(error) else {
                    throw error
                }
            }
        }

        try Task.checkCancellation()
        log.notice("Falling back to portable asset \(portableURL.lastPathComponent, privacy: .public)")
        return try await AIModel(contentsOf: portableURL, options: options)
    }
}
```

Cache deletion still belongs in a **separate, bounded repair path** after evidence points at a stale
specialization. A shipping community app uses this recovery step (`notes/repos/noema-ios.md:389-411`):

```swift prelude:guide-context
// Clear every cached variant of this model: each SpecializationOptions change
// leaves its own multi-GB entry behind, and stale/evicted entries are the
// documented way loads get wedged under storage pressure.
try? AIModelCache.default.deleteEntries(for: url)
```

That app's full ladder is: **cache probe → load → on failure, delete all entries for that URL and
retry → on second failure, retry with `.default` options**. It is useful evidence that cache repair
can recover a wedged specialization, not a universal rule for every `AIModel` throw. Apple's own
caching article uses `deleteEntries(for:)` when the source model is being replaced and the previous
specialization is no longer valid; keep that lifecycle operation distinct from generic error
handling.[^untyped-fallback-policy] §9 explains why the last rung is a symptom of a deeper problem
you should fix instead.

**Layer 4 — an honest error.** If a verified fallback reaches the portable path and that fails — or
an unclassified compiled load is rethrown — do not report "network error".
Use `ModelPreparationFailure.noVariantForArchitecture(String)` from §2.3 only when the architecture
variant is positively missing; keep an unknown load failure as a generic model-preparation error.
In either case, telemetry should carry `AIModel.deviceArchitectureName`, the one string that lets
you distinguish an asset-map defect from a transient runtime failure.

---

## 6. Specialization after download

### 6.1 What specialization is, precisely

The one-paragraph version, Apple's own:

> "When you load a `.aimodel` file with `AIModel`, Core AI performs **specialization**, the process
> of optimizing the model for the current device's hardware. The `.aimodel` file contains your model
> in a **portable format that works across Apple devices**. Before the model can run, Core AI
> specializes it for the current device, producing **executable code tied to that device's hardware
> and OS version**."
>
> "By default, an `AIModel` automatically specializes the model and caches the result. On the first
> call, Core AI specializes the model and stores the output. On subsequent calls with the same model
> and options, Core AI loads the cached version rather than running the specialization process
> again, which reduces load times."

✅ VERIFIED — *Managing model specialization and caching* (`notes/web/apple-docs-coreai.md:1260-1261`).

Three consequences fall directly out of "tied to that device's hardware **and OS version**":

1. It cannot be done on your Mac for someone else's iPhone. (AOT does *part* of it — §4.1.)
2. It must be redone after an OS update. Apple states this as an absolute:
   *"**Regardless of policy, the system always purges assets when the OS updates**, as specialized
   assets are OS-version specific."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1043`).
3. It is expensive enough to need scheduling, which is §2's entire premise.

### 6.2 The three levers

Session 324 enumerates them, and they map cleanly onto three API calls.

**Lever 1 — probe the cache before committing to anything.**

> "First, Core AI gives you **programmatic access to the default model cache for your app**. You can
> **request to load models directly from it**. If **nil is returned, it is not present and requires
> specialization**."

✅ VERIFIED (`notes/transcripts/coreai-intro.md:921`) → `cache.model(for:options:)`.

**Lever 2 — specialize explicitly, decoupled from loading.**

> "Second, you can **request model specialization explicitly in your app independent of it being
> loaded**. You can do this **after downloading assets or when the user opts in to a feature** so
> the model is ready to go ahead of time."

✅ VERIFIED (`notes/transcripts/coreai-intro.md:923-924`) → `AIModel.specialize(contentsOf:...)`.
Note that Apple names the two triggers this guide is built around: *after downloading assets*, and
*when the user opts in to a feature*.

**Lever 3 — configure and manage.**

> "And there is a lot more control available. **SpecializationOptions** help configure how you want
> your model to be optimized for inference. With the **AIModelCache** you can also **delete entries
> you no longer need**, and **control the policy on how long entries persist**."

✅ VERIFIED (`notes/transcripts/coreai-intro.md:927-928`).

There is a **fourth** lever that neither session names and that is worth knowing: **warmup**. The
`apple/coreai-models` Swift package carries an explicit `warmup()` — *"Warm up the engine with a
dummy forward pass to **trigger kernel compilation**"* (✅ VERIFIED, Apple shipping source, quoted
at `notes/transcripts/coreai-intro.md:1518`). Loading a function is not the last expensive thing
that happens; the first real `run` can still pay a kernel-compilation cost. If your first-run
screen has the user's attention anyway, spend a little of it on a dummy inference.

⚠️ But **not always**. A community app documents the counter-case: for graphs that carry their KV
cache as ordinary I/O with a static capacity baked into the shape, prewarming **allocates the full
cache** and is a net loss. Its guard, verbatim (`notes/repos/noema-ios.md:436-439`,
community source):

```swift prelude:guide-context
guard CoreAIDecoder.hostCacheCapacity(in: descriptor) == nil else {
    print("[CoreAI] Skipping prewarm for host-cache graph; it would allocate the static KV cache.")
    return
}
```

### 6.3 The full preparation sequence

Apple's documented pre-specialization pattern, verbatim:

```swift prelude:guide-context
guard let localModelURL = try await downloadModel(forFeature: feature) else {
    throw AppError.failedToDownloadModel(feature)
}

// Specialize the model so it's ready before the person needs it.
try await AIModel.specialize(contentsOf: localModelURL, options: .default)

// The model is now specialized and cached. Future loads skip specialization.
let model = try await AIModel(contentsOf: localModelURL, options: .default)
```

✅ VERIFIED verbatim (`notes/web/apple-docs-coreai.md:1289-1299`), with the NOTE: *"Calling
`specialize` multiple times with the same model URL and options returns the cached result without
repeating the specialization process."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1300`).

That idempotence is what makes `specialize` safe to call from a retry button.

Composed with everything above — the delivery seam from §3.4, the compiled/portable choice from
§4.3, the fallback from §5.5, and the single options factory from §9:

```swift prelude:guide-context
import CoreAI
import OSLog

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct FeaturePreparer {

    let compiledDelivery: ModelDelivery   // MyModel.<arch>.aimodelc
    let portableDelivery: ModelDelivery   // MyModel.aimodel
    private let log = Logger(subsystem: "com.example.app", category: "prepare")

    /// Everything from "user tapped the button" to "the model is cached and
    /// loadable", with progress reporting for the part that has progress.
    func prepare(
        onDownloadProgress: @escaping @Sendable (Double?) -> Void,
        onPhaseChange: @escaping @Sendable (String) -> Void
    ) async throws -> PreparedModelRecord {

        // 1. Fetch. Prefer the compiled variant; a device with no compiled
        //    variant published for it falls through to the portable asset.
        onPhaseChange("Downloading")
        let localURL: URL
        let isCompiled: Bool
        if let compiled = try? await compiledDelivery.fetch(onProgress: onDownloadProgress) {
            localURL = compiled
            isCompiled = true
        } else {
            log.notice("No compiled variant for \(AIModel.deviceArchitectureName, privacy: .public); using portable asset")
            localURL = try await portableDelivery.fetch(onProgress: onDownloadProgress)
            isCompiled = false
        }

        // 2. Validate before spending minutes on a corrupt bundle.
        guard AIModelAsset.isValid(at: localURL) else {
            throw ModelPreparationFailure.corruptAsset
        }

        // 3. Specialize. ONE options factory — see §9.
        onPhaseChange("Preparing model")
        let options = ModelOptions.shared.options(for: localURL)
        let model = try await AIModel.specialize(
            contentsOf: localURL,
            options: options,
            cache: .default,
            cachePolicy: .persistent
        )

        // 4. Optional warmup, guarded (see §6.2).
        onPhaseChange("Warming up")
        if let name = model.functionNames.first,
           let function = try model.loadFunction(named: name) {
            await warmUpIfSafe(function)
        }

        // 5. Record everything needed to find this again — see §8.4.
        return PreparedModelRecord(
            bookmark: model.bookmarkData,
            localPath: localURL.lastPathComponent,
            assetVersion: isCompiled
                ? compiledDelivery.expectedVersion
                : portableDelivery.expectedVersion,
            architecture: AIModel.deviceArchitectureName,
            isCompiled: isCompiled,
            optionsFingerprint: ModelOptions.shared.fingerprint(for: localURL),
            specializedAt: .now
        )
    }
}
```

`model.functionNames` and `loadFunction(named:)` are ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:115-117`), with the documented semantics that `loadFunction`
*"throws on a load failure, and returns `nil` when no function with that name exists"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1184`). The default function name is `"main"` ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1189`), but taking `functionNames.first` is more robust for
multi-function models — a pattern also used by the community app
(`notes/repos/noema-ios.md:423`, `let functionName = model.functionNames.first ?? "main"`).

Also note, from the same doc: *"**Loading a function prepares the resources needed to run that
function and can also be expensive.**"* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1184`). Loading
is a second cost after specialization, and it is a good use of the tail of the first-run screen.

### 6.4 ⚠️ Specialization reports no progress

> ✅ **CONFIRMED ABSENCE (was a GAP) — there is no progress API for specialization in the
> macOS 27.0 beta SDK.** Apple's `AIModel` surface has `init(contentsOf:options:) async throws`
> and `static func specialize(...) async throws` and **nothing else**: no `Progress`, no delegate,
> no `AsyncSequence` of phases. Our full harvest of the 312-symbol Core AI index
> (`notes/web/apple-docs-coreai.md:7`) found nothing of the kind, and the SDK interface dump
> captured 2026-07-29, recaptured 2026-08-20 settles that there is no unindexed overload either — the complete public
> loading surface is four members, `bookmarkData`, `init?(resolvingBookmark:)`,
> `init(contentsOf:options:)` and `static specialize(...)` (✅ **SDK-verified** —
> `CoreAIDelegates-27.0-macos.swiftinterface:14-27`), and the adjacent `AIModelCache` surface
> (`:28-43`) adds cache selection/construction, lookup, and deletion. None of it reports progress.
>
> **STILL THE RULE:** do not fake a progress bar. Show an indeterminate indicator with **explanatory
> text and an honest time estimate**, and — because you know your own model — hardcode a
> conservative estimate measured on your slowest supported device. Apple's own sample string is a
> good model for tone: `"Preparing AI features. This may take a while…"` ✅ VERIFIED
> (`notes/web/apple-docs-coreai.md:1276`). A fake bar that stalls at 90% for ninety seconds is
> worse than no bar.

Two related observations. First, `AIModel(contentsOf:options:)` is `async` *specifically* because
of this — Apple: *"`init(contentsOf:options:)` is asynchronous **because specialization needs to
complete before a valid `AIModel` is returned**"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1182`). It is one long await with no intermediate signal.

Second, you *can* observe it during development. The Core AI debug gauge in Xcode's Debug navigator
breaks activity into three event types, one of which is exactly this: **"Specialization: Runtime
specialization of the model for the target device architecture. **This only appears for models that
aren't specialized ahead of time.**"** ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1514`). That
last sentence is a free A/B test for your AOT adoption: if the orange specialization bars vanish
after you switch to `.aimodelc`, it worked.

⚠️ The gauge only appears if your project **directly links** `CoreAI.framework` — Apple:
*"The gauge only appears in projects that link the Core AI framework."* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1498`). Linking it transitively through a package is not enough.

### 6.5 How long does this actually take?

Attributed numbers only. There is no Apple-published figure for specialization time.

| Measurement | Value | Attribution |
|---|---|---|
| True-cold specialize, GPU monolith, `.aimodel` (JIT) | **19.2 s** | community-measured, iPhone 17 Pro / iOS 27 beta, post cache-wipe, 2026-06-10 (`notes/repos/john-rocky-models.md:1194-1197`) |
| Same model, `.aimodelc` (AOT) | **4.9 s** (~4× faster) | same source, same session |
| Same model, warm (cached) | **0.0 s** both | same source — "the OS cache serves `.aimodelc` too" |
| 1.8 GB 35-layer ANE monolith, AOT `h18p`, cold load | **6.5–8.1 s**, no jetsam; available memory 6130 → ~2810 MB | community-measured, iPhone 17 Pro (`notes/repos/john-rocky-models.md:1182-1185`) |
| 4B decoder, iOS ANE bundle, cold static load | **~518 s**, 31 ANE regions — then warmup inference **died** | community-measured, iPhone 17 Pro (`notes/repos/john-rocky-models.md:1109`) |
| Six-model bundle, fixed-shape, `expectFrequentReshapes = false` | **all 6 loads in 2.6 s** | community-measured, iPhone 17 Pro, 2026-07-23 (`notes/repos/john-rocky-models.md:1147-1148`) |

Every row is **community-measured by one engineer on beta OSes**, per that archive's own sourcing
statement: *"Every number … is community-measured by one person on one Mac and one iPhone, on beta
OSes"* (`notes/repos/john-rocky-models.md:4482-4483`). None is an Apple figure. Use them for
order-of-magnitude planning — "seconds for a small model, tens of seconds to minutes for a large
one" — and measure your own.

The one qualitative claim Apple *does* make is unambiguous and matches: *"Specializing the model can
take a significant amount of time depending on model size and the compute unit types it targets"*
✅ VERIFIED (`notes/web/apple-docs-coreai.md:135`), and *"The specialization process **can take a
significant amount of time for very large models**"* ✅ VERIFIED
(`notes/transcripts/coreai-intro.md:912`).

### 6.6 Choosing compute units

Apple's guidance is unusually direct and worth following:

> "For advanced use cases, restrict specialization to CPU only with `.cpuOnly`, or prefer a specific
> compute unit with `init(preferredComputeUnitKind:)`. **For example, if your app runs a small model
> in the background, use `.cpuOnly` to avoid competing with foreground GPU work.**"
>
> "**In most scenarios, the default configuration offers the best performance, so test your app's
> performance carefully before overriding it.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1285-1286`).

The full surface:

```swift illustrative
struct SpecializationOptions     // Equatable, Hashable, Sendable

static let `default`: SpecializationOptions
static let cpuOnly: SpecializationOptions
init(preferredComputeUnitKind: ComputeUnitKind)

var allowedComputeUnitKinds: Set<ComputeUnitKind> { get }
var preferredComputeUnitKind: ComputeUnitKind? { get }
var expectFrequentReshapes: Bool                    // get set
```

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1066-1074`).

The discussion on `preferredComputeUnitKind` is the most operationally useful sentence Apple wrote
about this type, and it explains a lot of confusing Instruments traces:

> "When set, the specialization process maximizes use of this compute unit kind. **Fallback to other
> kinds in `allowedComputeUnitKinds` may still occur for operations or operation patterns that are
> incompatible with the preferred kind. Operation patterns refer to groups of operations that are
> fused or transformed together during specialization; an operation that is individually compatible
> with the preferred unit kind may be part of a fused pattern that is not.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1081`). "Preferred" is a hint. An op that *should* run
on the ANE may not, because it got fused into a pattern that cannot.

And on `.cpuOnly`, a subtlety that matters for a background-processing path: *"The resulting
specialized model only uses the CPU during inference. **Because all operations support the CPU, no
fallback to other compute units occurs.**"* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1078`).
`.cpuOnly` is the only setting with a total guarantee.

What Apple's own package does, for calibration (✅ VERIFIED, `apple/coreai-models`,
`ModelStructure.swift:70-81`, quoted at `notes/transcripts/coreai-intro.md:983-996`):

- `.neuralEngine` for **static-shape / chunked** models
- `.gpu` + `expectFrequentReshapes = true` for **dynamic-shape LLMs**

A community app's dispatch on the same axis, keyed off the bundle's directory naming
(`notes/repos/noema-ios.md:365-387`, community source), carries a warning worth repeating verbatim:

> "`ios-ane/` bundles are the dynamic graphs proven on the Neural Engine; `ios-gpu/` static
> monoliths use fp32 SSM intermediates + custom Metal kernels and **fail ANE specialization ("ANE
> cannot handle intermediate tensor type fp32")**; `gpu-pipelined/` and `macos/` are GPU graphs.
> **Exact path-component matches only — substring checks mis-fire on names like "gated-deltanet".**"

That last clause is a nice small bug: a `contains("ane")` check matches `gated-deltanet`. If you
route on filename, split on path components and compare exactly.

---

## 7. Updating a model

### 7.1 The sequence, from Apple

Apple ships the canonical update flow as four lines, and the ordering of those four lines is the
whole lesson:

```swift prelude:guide-context
func downloadAndUpdateModel(from remoteURL: URL, localModelURL: URL) async throws {
    let tempURL = try await downloadLatestModel(from: remoteURL)

    // Delete cached assets for the old model.
    let cache = AIModelCache.default
    try cache.deleteEntries(for: localModelURL)

    // Replace the old model with the new one.
    try FileManager.default.replaceItemAt(localModelURL, withItemAt: tempURL)

    // Specialize the updated model.
    try await AIModel.specialize(
        contentsOf: localModelURL,
        options: .default,
        cachePolicy: .persistent
    )
}
```

✅ VERIFIED verbatim — Apple's *Managing model specialization and caching* article
(`notes/web/apple-docs-coreai.md:1320-1337`).

Four steps: **download → delete old cache entries → replace the file → re-specialize.**

Why delete *before* replacing? Because the cache is keyed on the **source URL plus the
`SpecializationOptions`** — Apple: *"Each cache entry contains a specialized asset formed from a
specific `.aimodel` or `.aimodelc` and `SpecializationOptions` combination"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1019`). If you replace the file first, the same URL now denotes
different content, and you are relying on the system's change detection to notice. It probably will
— "source model change" is a documented purge condition — but "probably" is doing load-bearing work
in a sentence about a multi-gigabyte artifact. Delete explicitly.

The three deletion APIs, with Apple's own one-line summaries (✅ VERIFIED,
`notes/web/apple-docs-coreai.md:1339-1342`):

> - `deleteEntries(for:)` — "Ignores any `SpecializationOptions` and deletes all cache entries for a
>   specific `.aimodel`."
> - `deleteEntry(for:options:)` — "Deletes a single cache entry for a specific `.aimodel` and
>   `SpecializationOptions` combination."
> - `deleteAll()` — "Deletes all entries in the entire cache."

Plus a fourth that only appears on the reference page:

```swift illustrative
static func deleteEntry(referencedBy bookmark: Data) throws
```

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1016`), with the discussion: *"Because bookmark data
encodes both the specific cache instance and the entry within it, **this method is static and
requires no cache instance to call**."* That is the API you need in §8's world, where the source
file may no longer exist and the bookmark is your only handle on the entry.

**Use `deleteEntries(for:)`, not `deleteEntry(for:options:)`, on the update path.** Apple's
rationale: *"A model may have multiple entries in the cache. For example, one with `cpuOnly` and
another with `default`. This method deletes all of them."* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1028`). If your app has ever specialized this model under more
than one options value — and §9 is about how easily that happens without you knowing — the
single-entry delete leaves a multi-gigabyte orphan behind.

### 7.2 Versioning the asset

Apple's snippet updates a model *in place at the same URL*. That is the simplest thing and it has
one bad property: **there is a window during which the model is neither the old one nor the new
one.** `replaceItemAt` is atomic, but the specialize that follows is not instantaneous, and an app
that is killed between them wakes up with a new source file and no specialization — a state that
looks identical to "never prepared" except that the user has already waited once.

Version the path instead. The `URLSessionDelivery` in §3.4 already does this — its container is
`Application Support/Models/<version>/` — and the payoff appears here:

```swift prelude:guide-context
import Foundation
import CoreAI

/// A model version is a directory. Updating means preparing a NEW directory
/// while the OLD one keeps serving, then flipping a pointer, then reclaiming.
///
/// This costs peak disk (both versions co-resident during the update) and buys
/// zero-downtime updates and a trivial rollback.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
actor VersionedModelStore {

    struct Installed: Codable, Sendable {
        var version: String
        var assetName: String
        var architecture: String
        var installedAt: Date
    }

    private let root: URL
    private let defaultsKey = "model.installed"

    init(root: URL) { self.root = root }

    func currentInstalled() -> Installed? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Installed.self, from: data)
    }

    func directory(for version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true)
    }

    /// Prepares a new version alongside the current one. The current version
    /// remains fully usable for the entire duration of this call.
    func install(
        version: String,
        assetName: String,
        fetch: (URL) async throws -> URL,          // (destination dir) -> asset URL
        options: SpecializationOptions
    ) async throws -> Installed {

        let dir = directory(for: version)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let assetURL = try await fetch(dir)
        guard AIModelAsset.isValid(at: assetURL) else {
            try? FileManager.default.removeItem(at: dir)
            throw ModelPreparationFailure.corruptAsset
        }

        // Specialize the NEW asset at its OWN url. Because the URL differs from
        // the old version's, this creates a NEW cache entry rather than
        // invalidating the one currently in use. Both are live for a while.
        _ = try await AIModel.specialize(
            contentsOf: assetURL,
            options: options,
            cache: .default,
            cachePolicy: .persistent
        )

        let installed = Installed(version: version,
                                  assetName: assetName,
                                  architecture: AIModel.deviceArchitectureName,
                                  installedAt: .now)
        // The flip. One small atomic write; everything before it was preparation.
        UserDefaults.standard.set(try JSONEncoder().encode(installed), forKey: defaultsKey)
        return installed
    }

    /// Reclaims a superseded version: cache entries FIRST, then the files.
    ///
    /// The order matters. `deleteEntries(for:)` is keyed on the source URL, so
    /// deleting the directory first leaves you unable to name the entry you
    /// wanted to remove — and orphaned entries are multi-gigabyte.
    func reclaim(version: String) throws {
        let dir = directory(for: version)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for candidate in contents where AIModelAsset.isValid(at: candidate) {
                // May throw if an AIModel still references the entry — see §7.4.
                try AIModelCache.default.deleteEntries(for: candidate)
            }
        }
        try FileManager.default.removeItem(at: dir)
    }
}
```

The critical line is the comment on `deleteEntries` in `reclaim`. **Delete cache entries before you
delete files.** The cache is keyed by source URL; once the URL is gone you have lost the key. The
entry will eventually be purged under the default policy (source-asset-deleted is a documented purge
condition, §11.2) — but if you specialized with `.persistent`, as this guide recommends, *that
condition is exactly the one you turned off.* A `.persistent` entry whose source file you deleted
without calling `deleteEntries` is an orphan the system will not reclaim until the next OS update.

### 7.3 Keeping the app working while an update is in flight

The versioned layout gives you this for free, but it needs to be stated as a rule because the
in-place update in Apple's snippet does not.

**Rule: the model currently in use must not be the model being replaced.** Concretely:

- The new version downloads to a new directory. The old directory is untouched.
- The new version is specialized under its own URL, producing a *second* cache entry. Peak storage
  during an update is therefore roughly **2 × (asset + specialization)** — budget for it and check
  free space before you start (§11.4).
- The pointer flip is a single `UserDefaults` write. Before it, every code path resolves to the old
  version; after it, to the new. There is no intermediate state in which the feature is broken.
- Reclamation happens *later* — on next launch, or when the app is backgrounded, never immediately
  after the flip. A live `AIModel` or `InferenceFunction` may still be holding the old entry, and
  §7.4 explains what happens if you try to delete it while it is held.

**Also handle the reverse case: the app updated, the model did not.** Your binary now expects a
different function signature, a different tokenizer, a different input name. This is where
`InferenceFunctionDescriptor` earns its place, and Apple names exactly this use:

> "You can use this descriptor to verify that a function accepts the inputs your app provides, or to
> **dynamically adapt your app's behavior as the model's inputs and outputs change between
> deployments, without needing to change your code**."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1210`).

```swift compile:27
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelContract {

    /// Fails fast, with a specific message, when the installed model does not
    /// match what this build of the app expects.
    ///
    /// Run this immediately after loading and BEFORE the feature is reachable.
    /// A mismatch caught here is a clean "please update" dialog; the same
    /// mismatch caught at inference time is a crash or, worse, nonsense output.
    static func validate(
        _ function: InferenceFunction,
        expectingInputs expectedInputs: Set<String>,
        outputs expectedOutputs: Set<String>
    ) throws {
        let descriptor = function.descriptor
        let actualInputs = Set(descriptor.inputNames)
        let actualOutputs = Set(descriptor.outputNames)

        guard expectedInputs.isSubset(of: actualInputs) else {
            throw ModelContractError.missingInputs(
                expectedInputs.subtracting(actualInputs).sorted())
        }
        guard expectedOutputs.isSubset(of: actualOutputs) else {
            throw ModelContractError.missingOutputs(
                expectedOutputs.subtracting(actualOutputs).sorted())
        }

        // States are not optional. Apple: "You must provide a mutable view for
        // every state when calling run(inputs:states:outputViews:)."
        // A model that grew a state your code does not supply will throw at run
        // time, so surface it here instead.
        if !descriptor.stateNames.isEmpty {
            print("model declares states: \(descriptor.stateNames)")
        }
    }
}

enum ModelContractError: Error {
    case missingInputs([String])
    case missingOutputs([String])
}
```

`InferenceFunctionDescriptor`'s members — `name`, `inputCount`, `inputNames`,
`inputDescriptor(of:)`, `outputCount`, `outputNames`, `outputDescriptor(of:)`, `stateNames`,
`stateDescriptor(of:)` — are ✅ VERIFIED (`notes/web/apple-docs-coreai.md:505-519`), as is the
states requirement: *"States are function arguments that the function both reads and writes during
inference. **You must provide a mutable view for every state** when calling
`InferenceFunction/run(inputs:states:outputViews:)`."* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:523`).

Note the asymmetry, worth knowing: there is `inputCount` and `outputCount` but **no `stateCount`**
(`notes/web/apple-docs-coreai.md:525`). Use `stateNames.count`.

### 7.4 ⚠️ Deleting an entry that is still in use: the docs contradict each other

> ⚠️ **Two Apple sources disagree about what happens when you delete a cache entry that a live
> `AIModel` still references.**
>
> The **reference pages** say it throws. This NOTE is repeated on all four delete APIs, verbatim:
> *"For each entry, if no `AIModel` instance currently references it, deletion happens immediately.
> **Otherwise, an error is thrown.** Deletion can only occur for an entry when the last `AIModel`
> releases it."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1029`).
>
> The **prose article** says it defers: *"If an `AIModel` instance still uses a cache entry, Core AI
> defers deletion until that instance is deallocated."* ✅ VERIFIED
> (`notes/web/apple-docs-coreai.md:1343`).
>
> These describe different behaviours. On an iPhone 15 Pro running iOS build `24A5408d`, the
> runtime followed the reference pages: `deleteEntries(for:)` threw
> `AIModelCacheError.failedToPurge` while a live model pinned the entry, the entry remained
> findable, and deletion succeeded after release. That dynamic error type is not public in the
> captured beta SDK, so do not pattern-match it.
>
> **SAFE DEFAULT:** release every `AIModel` and
> `InferenceFunction` for the entry first, then delete, then treat a throw as recoverable and retry
> once on the next app lifecycle event. Never rely on deferred deletion to reclaim storage you have
> promised the user — verify by re-measuring the directory (§11.6).

The mechanism behind the disagreement is documented and consistent even if the outcome is not:
`AIModel` **pins** its cache entry. Apple states this from the other direction in the `bookmarkData`
note: *"Bookmark data is just data. It does not pin entries in the cache. **Only a `AIModel` will
pin its associated entry in the cache while it is held.**"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:153`). That sentence is doing double duty — it is the pinning rule
*and* the setup for §8.

Practical consequence for the `reclaim(version:)` function in §7.2: call it from a place where you
can guarantee no model is loaded. On launch before any feature is reachable is the easy one.

### 7.5 Rollback

The versioned layout makes rollback nearly free, and you want it, because a bad model ships exactly
as easily as a good one and unlike a bad binary you can fix it without review.

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension VersionedModelStore {

    /// Reverts to a previously-installed version whose files are still present.
    /// Returns false if the target version has already been reclaimed.
    func rollback(to version: String) -> Bool {
        let dir = directory(for: version)
        guard FileManager.default.fileExists(atPath: dir.path),
              let asset = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil))?
                    .first(where: { AIModelAsset.isValid(at: $0) })
        else { return false }

        let installed = Installed(version: version,
                                  assetName: asset.lastPathComponent,
                                  architecture: AIModel.deviceArchitectureName,
                                  installedAt: .now)
        guard let data = try? JSONEncoder().encode(installed) else { return false }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return true
    }
}
```

The policy question this raises: **how long do you keep the previous version?** Keeping it doubles
your storage footprint indefinitely, which §11 says is exactly the thing users will complain about.
A reasonable default is *keep the previous version until the new one has completed one successful
inference, then reclaim on the next launch* — that is a cheap definition of "the update worked" and
it bounds the double-storage window to hours rather than months.

---

## 8. ⚠️ SILENT FAILURE: the bookmark that quietly stops working

### 8.1 Why bookmarks exist at all

Start with the problem they solve, because it is a good problem and the solution is genuinely
useful — which is precisely what makes the failure mode dangerous.

You have downloaded a 1.8 GB `.aimodel`, specialized it, and the specialized asset now also lives
on disk inside the Core AI cache. You are storing the model twice. The obvious move is to delete
the source. Apple says you cannot, and explains why:

> "The unspecialized `.aimodel` file, **along with the `SpecializationOptions` you pass**, is what
> Core AI uses to index and retrieve the cached specialization at runtime when you call
> `init(contentsOf:options:)` or `model(for:options:)`. Because of this, **you can't simply delete
> the source file and expect those APIs to keep working.** Instead, save a bookmark to the cached
> specialization and load the model directly from that bookmark on later launches."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1374`).

So the source file is the *key*, not just the input. Delete it and you have a specialized asset you
cannot name. The bookmark is the alternate key.

Apple's three-step workflow, verbatim:

```swift prelude:guide-context
// Specialize and keep a reference to the model.
let model = try await AIModel.specialize(
    contentsOf: llmURL,
    options: .default,
    cachePolicy: .persistent
)

// Save bookmark data to restore access after the app exits.
let bookmarkData = model.bookmarkData
UserDefaults.standard.set(bookmarkData, forKey: "llm.bookmark")
```

```swift illustrative
if let bookmarkData = UserDefaults.standard.data(forKey: "llm.bookmark") {
    do {
        if let model = try AIModel(resolvingBookmark: bookmarkData) {
            // Use the model.
            return model
        }
        // The model can't be found or was invalidated by an OS update.
    } catch {
        // The bookmark data is invalid.
    }
}

// Download and specialize the model again.
```

```swift prelude:guide-context
// Delete the source model to reclaim storage.
try FileManager.default.removeItem(at: llmURL)
```

✅ VERIFIED verbatim — all three snippets from Apple's article
(`notes/web/apple-docs-coreai.md:1376-1406`). The variable name `llmURL` in Apple's own sample is a
strong hint about who this workflow is for.

### 8.2 The defect

> ⚠️ **SILENT FAILURE.** `AIModel.bookmarkData` **does not pin the cache entry**, and
> `AIModel(resolvingBookmark:)` **returns `nil` rather than throwing** when the entry has been
> purged or invalidated. The failure therefore lands in an `else` branch — or, in Apple's own sample
> above, in a *bare comment* — and not in a `catch`. It is amplified by the fact that the entire
> point of the workflow is that you already **deleted the source `.aimodel`**, so recovery means a
> full re-download plus a full re-specialization.

Both halves are documented, on the same reference page, three lines apart.

**The pinning half**, from `bookmarkData`'s NOTE, verbatim:

> "**Bookmark data is just data. It does not pin entries in the cache. Only a `AIModel` will pin its
> associated entry in the cache while it is held.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:153`).

**The nil half**, from `init?(resolvingBookmark:)`:

> "If the bookmark data can be resolved, the resulting `AIModel` pins and references the cache entry
> as the model that generated the bookmark data. **If it cannot be resolved due to the specialized
> asset entry no longer being present nil is returned.**"
>
> "Resolving bookmark data involves checking it is a valid bookmark, validating the associated cache
> and cache entry it references exists, and returning a AIModel constructed with that specialized
> asset contained within that entry. **If any of these steps fail, nil is returned**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:141-142`).

And the crucial distinction, which is the reason a `catch` block is not enough:

> "**If the bookmark data is malformed due to not being sourced from AIModel.bookmarkData an error
> is thrown**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:143`). So:

| Situation | Result |
|---|---|
| Bookmark is garbage / not from `bookmarkData` | **throws** |
| Bookmark is well-formed but the entry was purged, or the OS updated, or you deleted it | **returns `nil`** |

The interesting failure is the one that returns `nil`. Your `catch` will never run.

Apple names the causes explicitly:

> "Bookmark data doesn't prevent removing assets from the device. **If the system purges the assets,
> you manually delete them, or an OS update invalidates them, your app can't resolve the bookmark
> and needs to download and specialize the model again.**"

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1407`).

The OS-update cause is not hypothetical or rare. It is **guaranteed**, on a schedule the user
controls, and no cache policy prevents it:

> "**Regardless of policy, the system always purges assets when the OS updates**, as specialized
> assets are OS-version specific."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1043`). Every user of your app who takes an iOS point
update will hit this branch. Not "may hit" — will hit. That is the difference between an edge case
and a routine event that your code must handle gracefully, and it is why this failure deserves a
callout rather than a footnote.

### 8.3 Why it is easy to get wrong

Look again at Apple's sample. It is not badly written; it is *deliberately schematic*, and that is
the trap:

```swift prelude:guide-context
        if let model = try AIModel(resolvingBookmark: bookmarkData) {
            // Use the model.
            return model
        }
        // The model can't be found or was invalidated by an OS update.
```

That trailing comment is the entire handling of the guaranteed-to-happen case. Copy this into a
real app and the natural completion is:

```swift prelude:guide-context
// The obvious, wrong completion:
if let model = try AIModel(resolvingBookmark: bookmarkData) {
    return model
}
// ...fall through to "download and specialize the model again"
```

— but you deleted the source file in step three. Where do you download from? What version were you
on? Which architecture variant did this device get? **The bookmark contains none of that.** It is
opaque cache-entry data, and the moment it stops resolving you have lost every fact you needed in
order to recover.

That is the actual defect: not that resolution can fail, but that the *only* thing you persisted was
the thing that stops working, and you deleted the thing that would have let you rebuild it.

### 8.4 The fix: persist a record, never a bare bookmark

Store the bookmark as **one field of a record** that also carries everything needed to reconstruct
the model from scratch. The record is a few hundred bytes; the thing it protects is a
multi-gigabyte, multi-minute recovery.

```swift compile:27
import Foundation
import CoreAI

/// Everything needed to (a) reopen a specialized model fast, and (b) rebuild it
/// from nothing if (a) fails.
///
/// The bookmark is ONE FIELD. It is the fast path and it is expected to break —
/// guaranteed on every OS update. Every other field exists so that breaking is
/// a recoverable event rather than a dead end.
struct PreparedModelRecord: Codable, Sendable, Equatable {

    /// Fast path. `AIModel.bookmarkData`. May stop resolving at any time.
    var bookmark: Data

    /// Where the source asset was, relative to the models container. Present
    /// even if you deleted the file — this is what you re-download INTO.
    var localPath: String

    /// Where to get it again. The version-pinned remote identity.
    var remoteAssetName: String
    var assetVersion: String

    /// Which variant this device got. Recorded because `deviceArchitectureName`
    /// could in principle change across an OS update, and because it is the
    /// single most useful field in a crash report (§5.5).
    var architecture: String
    var isCompiled: Bool

    /// A stable identity for the SpecializationOptions used. See §9 — a
    /// mismatch here means you are about to create a SECOND multi-gigabyte
    /// specialization rather than reuse the first.
    var optionsFingerprint: String

    /// When the specialization was produced. Lets you detect "specialized under
    /// a previous OS build" without waiting for a resolution failure.
    var specializedAt: Date

    /// The OS build the specialization was produced under. If this differs from
    /// the current build, the entry is already gone — Apple purges on every OS
    /// update regardless of policy — so you can skip the doomed resolve.
    var osBuild: String
}
```

The loader that uses it. Note that there are **three** outcomes, not two, and each is handled
separately:

```swift prelude:guide-context
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum RecordedModelLoader {

    enum Outcome {
        /// Bookmark resolved. Zero work.
        case reopened(AIModel)
        /// Bookmark is gone but the source asset is still on disk. Re-specialize
        /// only — no download. Tens of seconds.
        case needsRespecialization(URL)
        /// Source asset is also gone. Full recovery: download + specialize.
        case needsFullRecovery(assetName: String, version: String)
    }

    static func open(
        _ record: PreparedModelRecord,
        modelsRoot: URL,
        currentOSBuild: String,
        options: SpecializationOptions
    ) -> Outcome {

        let sourceURL = modelsRoot.appendingPathComponent(record.localPath)
        let sourceExists = AIModelAsset.isValid(at: sourceURL)

        // Skip a resolve that cannot succeed. Apple purges every specialized
        // asset on OS update, unconditionally, so a record from a previous build
        // is known-stale before we ask.
        if record.osBuild == currentOSBuild {
            do {
                if let model = try AIModel(resolvingBookmark: record.bookmark) {
                    return .reopened(model)
                }
                // ⚠️ THE SILENT BRANCH. Well-formed bookmark, entry gone.
                // This is not an error condition; it is a routine one.
            } catch {
                // Malformed bookmark — a bug in our persistence, or migrated
                // data from an older schema. Same recovery, different log level.
                assertionFailure("Malformed bookmark: \(error)")
            }
        }

        return sourceExists
            ? .needsRespecialization(sourceURL)
            : .needsFullRecovery(assetName: record.remoteAssetName,
                                 version: record.assetVersion)
    }
}
```

Three properties of this shape worth naming:

1. **The `nil` branch and the `catch` branch converge on the same recovery**, which is correct —
   both mean "the fast path is unavailable" — but they are logged differently, because one is
   routine and one is a bug in your code.
2. **The `osBuild` check turns a guaranteed failure into a skipped call.** After an OS update you
   *know* the entry is gone. Asking anyway costs nothing but it also tells you nothing; checking
   first lets you go straight to `.needsRespecialization` and, more importantly, lets you tell the
   user *"iOS updated, so we need a minute to re-prepare the model"* instead of showing a spinner
   with no explanation.
3. **`.needsRespecialization` is a genuinely different and much cheaper state than
   `.needsFullRecovery`.** Conflating them — which is what happens if all you kept was a bookmark —
   turns a 20-second re-specialize into a 1.8 GB download. This is the single largest practical
   payoff of persisting a record.

### 8.5 Should you delete the source asset at all?

Having built all that, the honest answer is: **often, no.**

The bookmark workflow exists to reclaim the source asset's storage after specialization. Weigh it:

**Deleting the source buys you** roughly the size of the `.aimodel` — call it 1× — at the cost of
making every cache-purge event a full re-download.

**Keeping the source costs you** that 1×, and makes every cache-purge event a re-specialization,
which is seconds-to-minutes of local compute and **zero** network.

Given that OS updates guarantee purges, and given that a user on cellular who just updated iOS is
exactly the person you least want to hand a 1.8 GB download to, keeping the source is usually
right. Delete it if, and only if:

- your model is large enough that the doubled storage is itself the user complaint, **and**
- you have a fast, resumable, Wi-Fi-preferring download path, **and**
- you have implemented the record from §8.4 so that recovery is precise rather than panicked.

If you do keep the source, note that you then do **not** strictly need `.persistent` — the default
policy's purge conditions (`sourceAssetChangedOrDeleted`, `storagePressure`) are both survivable
when you can re-specialize locally. §11.2 has the full policy comparison. But `.persistent` still
saves your users the re-specialization under storage pressure, and specialization is not cheap, so
this guide's default remains `.persistent` **plus** keeping the source.

### 8.6 Cleaning up a bookmark you are done with

When you retire a model version and its source file is already gone, `deleteEntries(for:)` cannot
help — you have no URL. Use the static, bookmark-keyed delete:

```swift prelude:guide-context
// Reclaim a specialized asset whose source .aimodel no longer exists.
// Static: "Because bookmark data encodes both the specific cache instance and
// the entry within it, this method is static and requires no cache instance."
try AIModelCache.deleteEntry(referencedBy: record.bookmark)
```

✅ VERIFIED — `static func deleteEntry(referencedBy bookmark: Data) throws`
(`notes/web/apple-docs-coreai.md:1016, 1032`).

⚠️ Subject to the same live-reference pin as §7.4: the reference page's NOTE about throwing when an
`AIModel` still references the entry is repeated on **all four** delete APIs, this one included.
The URL-keyed device probe selected that throws branch; release the model first.

---

## 9. ⚠️ SILENT FAILURE: two options structs, two multi-gigabyte specializations

### 9.1 The defect

> ⚠️ **SILENT FAILURE.** `SpecializationOptions` is **part of the cache key** and is a **struct with
> a mutable property**. Two code paths that construct *slightly* different options silently produce
> **two separate multi-gigabyte specializations**. There is no error, no warning, and no log line.
> The symptom is a first-load stall that reappears after you were certain you had fixed it, plus
> storage that grows by an integer multiple of your model size.

The two facts that combine into this are both ✅ VERIFIED and both innocuous on their own.

**Fact 1 — options are in the key.** Apple, on `AIModelCache`: *"Each cache entry contains a
specialized asset formed from a specific `.aimodel` or `.aimodelc` **and `SpecializationOptions`
combination**."* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1019`). And on `deleteEntries(for:)`,
Apple spells out the consequence with an example: *"A model may have multiple entries in the cache.
For example, one with `cpuOnly` and another with `default`. This method deletes all of them."*
✅ VERIFIED (`notes/web/apple-docs-coreai.md:1028`).

The type is `Hashable` — ✅ VERIFIED, its conformance list is
`Equatable, Hashable, Sendable, SendableMetatype` (`notes/web/apple-docs-coreai.md:1066`) — which
is exactly what you would expect of something used as a dictionary key.

**Fact 2 — one of its properties is mutable.** `expectFrequentReshapes` is the only non-`get`-only
member: `var expectFrequentReshapes: Bool { get set }` ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1074`), and there is **no initializer that sets it** — the only
`init` is `init(preferredComputeUnitKind:)` (✅ VERIFIED,
`notes/web/apple-docs-coreai.md:1070, 1082`). So the only way to set it is post-construction
mutation, which means the value depends on *how far down a function you got*.

Put those together and you have a hashable cache key whose value is assembled imperatively across
however many lines of setup code you wrote.

### 9.2 How it actually happens

Here is the bug in the shape it really takes. Three call sites, written weeks apart, all "obviously"
constructing the same options.

```swift compile:27 imports:Foundation,CoreAI
// ❌ THE BUG. Do not do this.

// Call site A — the first-run screen (§2). Written first, by whoever built the
// onboarding flow.
func prepareOnFirstRun(url: URL) async throws {
    let options = SpecializationOptions(preferredComputeUnitKind: .gpu)
    try await AIModel.specialize(contentsOf: url, options: options,
                                 cachePolicy: .persistent)
}

// Call site B — the cache probe on every appearance of the feature screen.
// Written second, by someone who read Apple's article and used `.default`.
func isModelReady(url: URL) -> Bool {
    (try? AIModelCache.default.model(for: url, options: .default)) != nil
}

// Call site C — the actual load, in the inference engine. Written third, by
// whoever was tuning performance, who read §5.4 and added the reshape hint.
func load(url: URL) async throws -> AIModel {
    var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
    options.expectFrequentReshapes = true          // ← the divergence
    return try await AIModel(contentsOf: url, options: options)
}
```

Trace what the user experiences:

1. First-run screen runs A. **Specialization #1** is produced under
   `(gpu, expectFrequentReshapes: <default>)`. Several gigabytes, several tens of seconds. The
   screen says "Ready."
2. User opens the feature. B probes with `.default` — a *different* key — gets `nil`, and the UI
   says the model is **not** ready. Depending on how you wired §2.3, this either shows the opt-in
   button again or silently re-enters the preparing state.
3. The user taps into the feature anyway. C loads with `(gpu, expectFrequentReshapes: true)` — a
   *third* key. No cache hit. **Specialization #2** runs, in the interactive flow, which is exactly
   the bug §2 was written to prevent.
4. Storage now holds two full specializations. `deleteEntry(for:options:)` called with any one of
   the three options values removes at most one of them.

Nothing threw. Nothing logged. The only observable is "the first-load stall came back" and a
storage number that is roughly double what your arithmetic predicted.

There is a fourth-order version of this that is nastier still. §5.4 documents that
`expectFrequentReshapes = true` on a fixed-shape graph **stops the runtime using the AOT
specialization and compiles on device**, which on one measured configuration segfaults
(community-measured, iPhone 17 Pro, 2026-07-23, `notes/repos/john-rocky-models.md:1132-1144`). So
divergent options do not merely waste storage — they can route you onto a code path that crashes,
from a call site that looks identical to the one that works.

### 9.3 Evidence this is a real, encountered problem

Not a theoretical concern. A shipping community iOS app carries a recovery ladder specifically for
it, and its comment is the clearest field statement of the failure
(`notes/repos/noema-ios.md:389-411`, community source, quoted verbatim):

```swift prelude:guide-context
// Clear every cached variant of this model: each SpecializationOptions change
// leaves its own multi-GB entry behind, and stale/evicted entries are the
// documented way loads get wedged under storage pressure.
try? AIModelCache.default.deleteEntries(for: url)
```

The same app's summary list of Core AI gotchas states it flatly as item 16:

> "Every distinct `SpecializationOptions` leaves its own multi-GB cache entry;
> `AIModelCache.default.deleteEntries(for:)` on failure, then retry, then fall back to `.default`."

Community-measured, `notes/repos/noema-ios.md:2073`.

Note what that app's recovery ladder actually is: *delete everything and re-specialize.* That is the
correct emergency response and a terrible steady state — it means paying full specialization cost to
recover from a bug that a single shared factory would have prevented.

### 9.4 The fix is structural

The lesson is not "be careful." Being careful does not survive three developers and eighteen months.
The lesson is: **there must be exactly one place in your app that constructs a
`SpecializationOptions`, and every API that takes one must be fed from it.**

The three APIs that take options — and therefore the three that must agree — are:

```swift illustrative
AIModelCache.model(for:options:)                    // the probe
AIModel.init(contentsOf:options:)                   // the load
AIModel.specialize(contentsOf:options:cache:cachePolicy:)   // the warm
```

All ✅ VERIFIED (`notes/web/apple-docs-coreai.md:111, 121-124, 1011`). Plus, for deletion:

```swift prelude:guide-context
AIModelCache.deleteEntry(for:options:)              // the targeted delete
```

Four call sites, one source of truth:

```swift compile:27
import CoreAI
import CryptoKit
import Foundation

/// The ONE place in the app that constructs SpecializationOptions.
///
/// Why a type and not a global function: the fingerprint has to be derived from
/// the same decision the options are, and keeping them adjacent is what stops
/// them drifting. Anything that needs options gets them from here, including
/// tests.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct ModelOptions: Sendable {

    static let shared = ModelOptions()

    /// The single decision function. Every branch must be reachable from a
    /// property of the model itself — never from a caller's context, never from
    /// a feature flag read at call time, never from "which screen am I on".
    func options(for modelURL: URL) -> SpecializationOptions {
        switch shape(of: modelURL) {
        case .staticShapeChunked:
            // Apple's own package picks .neuralEngine for static-shape/chunked
            // models (coreai-models, ModelStructure.swift:70-81).
            return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)

        case .dynamicShapeLLM:
            // ...and .gpu + expectFrequentReshapes for dynamic-shape LLMs.
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            options.expectFrequentReshapes = true
            return options

        case .staticShapeGPU:
            // ⚠️ Explicitly FALSE, not "left at the default". §5.4: asking for
            // the reshape hint on a fixed-shape graph was measured to abandon
            // the AOT specialization and SIGSEGV on device.
            var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
            options.expectFrequentReshapes = false
            return options

        case .unknown:
            // Apple: "In most scenarios, the default configuration offers the
            // best performance, so test your app's performance carefully before
            // overriding it."
            return .default
        }
    }

    /// A stable string identity for the options this model gets, for persisting
    /// in `PreparedModelRecord` (§8.4) and for logging.
    ///
    /// This is deliberately derived from the same `shape(of:)` call, so it
    /// cannot disagree with `options(for:)`.
    func fingerprint(for modelURL: URL) -> String {
        let opts = options(for: modelURL)
        let preferred = opts.preferredComputeUnitKind.map(String.init(describing:)) ?? "none"
        let allowed = opts.allowedComputeUnitKinds
            .map(String.init(describing:)).sorted().joined(separator: "+")
        let raw = "v1|pref=\(preferred)|allowed=\(allowed)|reshapes=\(opts.expectFrequentReshapes)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.prefix(16).joined()
    }

    private enum Shape { case staticShapeChunked, dynamicShapeLLM, staticShapeGPU, unknown }

    /// Classify from the asset itself, not from caller context.
    ///
    /// This example keys off path components, which is what a bundle layout with
    /// `ios-ane/`, `ios-gpu/`, `gpu-pipelined/` directories permits. If your
    /// assets carry creator-defined metadata instead, read that — see §9.5.
    ///
    /// ⚠️ Exact component matches only. A `contains("ane")` substring check
    /// matches "gated-deltanet".
    private func shape(of url: URL) -> Shape {
        let components = Set(url.pathComponents.map { $0.lowercased() })
        if components.contains("ios-ane")       { return .staticShapeChunked }
        if components.contains("ios-gpu")       { return .staticShapeGPU }
        if components.contains("gpu-pipelined") { return .dynamicShapeLLM }
        if components.contains("macos")         { return .dynamicShapeLLM }
        return .unknown
    }
}
```

The `SpecializationOptions` members read in `fingerprint` are ✅ VERIFIED:
`allowedComputeUnitKinds: Set<ComputeUnitKind> { get }`,
`preferredComputeUnitKind: ComputeUnitKind? { get }`, `expectFrequentReshapes: Bool { get set }`
(`notes/web/apple-docs-coreai.md:1072-1074`).

The `shape(of:)` classification mirrors a community app's dispatch and inherits its warning about
exact path-component matching (`notes/repos/noema-ios.md:365-387`).

Now every call site is a one-liner that cannot diverge:

```swift prelude:guide-context
// ✅ THE FIX. Every options-taking API is fed from the same factory.

func isModelReady(url: URL) -> Bool {
    (try? AIModelCache.default.model(
        for: url, options: ModelOptions.shared.options(for: url))) != nil
}

func prepare(url: URL) async throws {
    _ = try await AIModel.specialize(
        contentsOf: url,
        options: ModelOptions.shared.options(for: url),
        cache: .default,
        cachePolicy: .persistent)
}

func load(url: URL) async throws -> AIModel {
    try await AIModel(
        contentsOf: url, options: ModelOptions.shared.options(for: url))
}

func discard(url: URL) throws {
    // Note deleteEntries, not deleteEntry(for:options:) — belt and braces.
    // If a divergence ever DID occur, this cleans up all of it.
    try AIModelCache.default.deleteEntries(for: url)
}
```

### 9.5 Making the divergence impossible to reintroduce

The factory is necessary and not sufficient — someone can still write
`SpecializationOptions(preferredComputeUnitKind: .gpu)` inline. Three cheap defences:

**1. A lint rule.** One grep in CI:

```bash
# Fail the build if SpecializationOptions is constructed outside ModelOptions.swift.
if grep -rn --include='*.swift' \
     -e 'SpecializationOptions(' -e 'SpecializationOptions\.default' \
     -e 'SpecializationOptions\.cpuOnly' Sources/ \
   | grep -v 'Sources/Models/ModelOptions.swift' ; then
  echo "FATAL: SpecializationOptions constructed outside the factory. See guide §9." >&2
  exit 1
fi
```

**2. An assertion at every options-taking call site.** Since the type is `Equatable`, you can check
cheaply in debug builds:

```swift prelude:guide-context
@inline(__always)
func assertCanonical(_ options: SpecializationOptions, for url: URL) {
    assert(options == ModelOptions.shared.options(for: url),
           "Non-canonical SpecializationOptions for \(url.lastPathComponent). See guide §9.")
}
```

`SpecializationOptions: Equatable` is ✅ VERIFIED (`notes/web/apple-docs-coreai.md:1066`).

**3. A storage canary.** The clearest signal that a divergence has happened in production is
storage that exceeds one specialization per installed model. §11.6 shows the measurement; wire it to
a debug-menu warning and you will find the bug in a day rather than in a review of App Store
complaints.

**4. Classify from the asset, not the caller.** The `shape(of:)` function above reads path
components, which works for a bundle layout you control. A more robust source is the asset's own
metadata, which Core AI supports natively:

```swift prelude:guide-context
var asset = try AIModelAsset(contentsOf: modelURL)
// Read a creator-defined key stamped at export time.
let profile = asset.metadata["specializationProfile"] // String?
```

`AIModelAsset.Metadata` has typed subscripts for `String`, `Bool`, `Int`, `Double`, arrays and
dictionaries, plus `description`, `author`, `license`, `creationDate` and
`creatorDefinedMetadata: [String: CreatorDefinedValue]` — all ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:230-284`). And it is writable from a build script via
`updateMetadata(_:)`, whose documented example is exactly this pattern:

```swift prelude:guide-context
var asset = try AIModelAsset(contentsOf: input)
try asset.updateMetadata { metadata in
  metadata.author = "Alice"
  metadata.description = "An example model"
  metadata["iterations"] = 1000 // Custom metadata
}
```

✅ VERIFIED verbatim (`notes/web/apple-docs-coreai.md:205-212`). Stamping the intended
specialization profile into the asset at export time makes the app's classification a *lookup*
rather than an *inference*, which removes the last place a divergence can hide.

---

## 10. App groups: sharing one specialization across targets

### 10.1 The problem

Your app has a widget, a share extension, a Shortcuts action, or a sibling app. Each is a separate
process with a separate bundle, and — by default — a **separate Core AI cache**. Apple's
description of the default cache makes this explicit: *"The shared specialized asset cache **for
your app bundle**. The framework uses this cache by default whenever specialization happens
automatically, such as during `init(contentsOf:options:)`."* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1021`).

Per bundle. So an app and its extension that both use the same model, both loading from the same
shared container, will each specialize it separately, pay the cost separately, and store the result
separately. For a multi-gigabyte specialization that is not a rounding error.

### 10.2 The API

```swift illustrative
init?(appGroup groupIdentifier: String)
```

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1009`), with:

- **Parameter**: *"A string that names the group whose shared cache you want to obtain. **This input
  should exactly match one of the strings in the app's App Groups Entitlement.**"*
- **Return**: *"The shared app group cache, or `nil` when the group identifier is invalid **(on
  iOS)**, the app group container cannot be accessed, or entitlement checks fail."*
- **Discussion**: *"Use this initializer when multiple apps within an app group need to share a
  cache for their specialized assets. **This allows all apps within an app group to avoid each
  performing their own specialization for a shared model.**"*
- **Entitlement**: `com.apple.security.application-groups`

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1022-1026`).

Apple's usage examples, verbatim:

```swift prelude:guide-context
// Get the app group cache.
guard let groupCache = AIModelCache(appGroup: groupIdentifier) else {
    fatalError("Invalid group identifier or entitlement.")
    return
}

// Specialize into the shared cache.
try await AIModel.specialize(
    contentsOf: sharedModelURL,
    options: .default,
    cache: groupCache,
    cachePolicy: .persistent
)
```

```swift prelude:guide-context
guard let groupCache = AIModelCache(appGroup: groupIdentifier) else {
    return
}

if let model = try groupCache.model(for: sharedModelURL, options: .default) {
    // Use the model. No specialization needed.
}
```

✅ VERIFIED verbatim (`notes/web/apple-docs-coreai.md:1346-1368`), with Apple's summary of the
benefit: *"This avoids duplicating specializations across apps."*

### 10.3 ⚠️ The initializer returns `nil`, and Apple's own sample calls `fatalError`

Read that first snippet again. Apple's documented sample handles a `nil` cache by crashing.

That is fine as documentation — it makes the failure loud, and the failure is a *configuration*
error you should catch during development, not a runtime condition. But shipping it is a bad idea,
because the failure list has three entries and only one of them is under your control at build time:

1. **Invalid group identifier** (Apple annotates this "on iOS", which hints at platform-divergent
   behaviour — see the gap below).
2. **The app group container cannot be accessed.**
3. **Entitlement checks fail.**

Cause 2 is a runtime condition. A crash there takes down a widget or a share extension in front of
the user, for a recoverable problem.

Shipping shape:

```swift compile:27
import CoreAI
import OSLog

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum SharedModelCache {

    private static let log = Logger(subsystem: "com.example.app", category: "coreai")
    private static let groupID = "group.com.example.shared"

    /// The app-group cache when available, the per-bundle default otherwise.
    ///
    /// Degrading to `.default` is CORRECT behaviour, not a fallback hack: the
    /// feature still works, it just re-specializes in this process rather than
    /// reusing the shared entry. Crashing would be strictly worse.
    ///
    /// ⚠️ But this degradation is INVISIBLE unless you log it. A misconfigured
    /// entitlement silently doubles your specialization cost and storage, with
    /// no user-visible symptom other than a slow first run in the extension.
    static func cache() -> AIModelCache {
        guard let group = AIModelCache(appGroup: groupID) else {
            log.error("""
                App-group cache unavailable for \(groupID, privacy: .public) — \
                falling back to the per-bundle default cache. Check the \
                com.apple.security.application-groups entitlement on THIS target.
                """)
            assertionFailure("App group cache unavailable — fix the entitlement.")
            return .default
        }
        return group
    }
}
```

The `assertionFailure` gives you Apple's loudness in debug builds and the graceful path in release.

> 🔴 **GAP — the "(on iOS)" qualifier.** Apple's return documentation reads: *"`nil` when the group
> identifier is invalid **(on iOS)**, the app group container cannot be accessed, or entitlement
> checks fail."* The parenthetical is attached only to the first cause. Whether that means macOS
> behaves differently for an invalid identifier — throws? traps? succeeds with a useless cache? — is
> **not stated anywhere**. Flagged as an open question in our own harvest
> (`notes/web/apple-docs-coreai.md:1762`).
>
> **What would resolve it:** calling `AIModelCache(appGroup: "definitely-not-a-group")` on macOS 27
> and on iOS 27 and comparing.
>
> **SAFE DEFAULT:** treat `nil` as the only failure signal on every platform and do not write
> platform-conditional handling. Since the initializer is `init?` and not `throws`, `nil` is the
> only channel it has.

### 10.4 Getting the configuration right

Three things must line up, and a mismatch in any of them produces the silent degradation above.

**1. The entitlement, on every target that touches the cache.** Not just the app — the widget
extension, the share extension, and any sibling app. `com.apple.security.application-groups`,
containing the identifier string.

**2. The identifier string, character-exact.** Apple: *"This input should exactly match one of the
strings in the app's App Groups Entitlement."* Hardcoding it in two places is how it drifts. Put it
in a shared constant, in a target both bundles link.

**3. The model file, in the shared container.** The cache is keyed on the *source URL*. Two
processes sharing a cache but resolving the model to two different container paths get two entries —
the §9 failure, wearing a different hat. Resolve the model URL from the app group container:

```swift compile:27
import Foundation

enum SharedContainer {
    static let groupID = "group.com.example.shared"

    /// The one place the model URL is computed. Both the app and every
    /// extension MUST come through here, or they will produce distinct cache
    /// keys for the same bytes.
    static func modelURL(assetName: String, version: String) throws -> URL {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(assetName)
    }
}
```

### 10.5 Extensions have memory limits, and Core AI models count against them

Worth stating here because app groups are mostly an extension story, and this is the constraint that
decides whether the extension can use the model at all.

An Apple DTS Engineer, thread 833575 (✅ VERIFIED,
`notes/forums/forum-pain-points.md:580-586`):

> "The system language model (`SystemLanguageModel`) is **not loaded into the app / extension's
> memory**, and so using it **doesn't count on the memory limit of your extension**. **If you are
> using your own on-device model, the model will be loaded to the memory of your app / extension,
> and so you will need to test if that is fine for your extension.** Note that some extensions don't
> allow XPC due to privacy reason, and hence can't use a model via the Foundation Models framework."

That is the crisp statement of the tradeoff. Apple's built-in model is free of your memory budget
because it lives elsewhere. **Your** model is not. A share extension with a tight limit and a 1.8 GB
model is not a configuration problem you can entitle your way out of.

Note also that the resource ownership sits with the *function*, not the model:
*"The model instance is lightweight and doesn't own weights or intermediate buffers. Those resources
belong to the functions you load from it"* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:105`), and
`InferenceFunction` *"owns the resources needed for inference, including model weights and
intermediate buffers"* ✅ VERIFIED (`notes/web/apple-docs-coreai.md:318`). So an extension can hold
an `AIModel` cheaply and defer the expensive `loadFunction(named:)` until it is certain it needs it.

⚠️ One more memory note from the same reference page, easy to miss and directly relevant to a
memory-constrained extension: `InferenceFunction` is `Sendable` and *"The function automatically
allocates additional intermediate buffers as needed to support concurrency"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:319`). Concurrent `run` calls silently grow scratch memory. In an
app that is a performance knob; in an extension it is a jetsam risk. Serialize inference in
memory-constrained targets.

### 10.6 When app groups are the wrong answer

- **One app, one process.** The default cache is already shared across your app's own launches.
  Adding an app group buys nothing and adds an entitlement that can fail.
- **The extension needs different specialization options.** Two options values are two cache
  entries whether or not the cache is shared (§9). Sharing the cache does not merge them; it just
  puts both copies in the shared container. If your extension genuinely needs `.cpuOnly` — a
  reasonable choice, per Apple's own example about background work — then it is paying for its own
  specialization regardless, and the app group only helps with the *storage location*, not the cost.
- **The models are genuinely different.** Session 326's multiplatform recipe swaps the model per
  platform — Qwen3 0.6B on iOS, Qwen3 8B on macOS (✅ VERIFIED,
  `notes/transcripts/coreai-intro.md:1763-1773`). Different models, different assets, nothing to
  share.

---

## 11. Storage hygiene

### 11.1 What is on disk, and how many copies

Count them honestly, because users will.

| Artifact | Present when | Rough size |
|---|---|---|
| Source `.aimodel` or `.aimodelc` | always, unless you adopted §8's delete-the-source workflow | 1× (`.aimodel`), ~2× (`.aimodelc`, community-measured) |
| Specialized asset in the cache | after specialization | model-dependent; assume ≥ 1× |
| Previous version's source | during and after an update, until reclaimed (§7) | another 1–2× |
| Previous version's specialization | same window | another ≥ 1× |
| **A second specialization from divergent options** | **§9's bug** | **another ≥ 1×, invisibly** |

A model whose `.aimodel` is 1.8 GB can therefore occupy anywhere from ~3.5 GB (steady state, source
plus specialization) to well over 10 GB (mid-update, with a §9 divergence). That is the range your
storage screen has to be able to explain.

The `.aimodelc` multiplier is community-measured — *"the result (`*.h18p.aimodelc`, **~2× the
`.aimodel` size**) embeds the precompiled graph"* (`notes/repos/john-rocky-models.md:879-880`,
iPhone 17 Pro target, 2026-06-10). No Apple figure exists for the specialized-asset size, which is
why the table says "assume ≥ 1×" rather than giving a number.

### 11.2 Cache policies: what the system may take back

```swift illustrative
struct AIModelCache.Policy      // Codable, Equatable, Hashable, Sendable
static let `default`: AIModelCache.Policy
static let persistent: AIModelCache.Policy
init(purgeConditions: AIModelCache.Policy.PurgeConditions)
var purgeConditions: AIModelCache.Policy.PurgeConditions { get }

struct AIModelCache.Policy.PurgeConditions   // OptionSet
static let sourceAssetChangedOrDeleted: PurgeConditions
static let storagePressure: PurgeConditions
```

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1034-1056`).

The two shipped policies, in Apple's words:

- **`.default`** — *"The default policy marks a specialized asset as purgeable. The system can
  delete it when low on storage or when its source `.aimodel` changes or you delete it."*
- **`.persistent`** — *"This policy ensures the system does not purge specialized assets **until the
  next OS update**. You can manually delete them, but the system does not automatically purge them
  under low storage or when the source `.aimodel` changes."*

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1045-1046`).

And the condition that overrides both, stated twice by Apple in two different places:

> ⚠️ **NOTE:** "**Regardless of policy, the system always purges assets when the OS updates**, as
> specialized assets are OS-version specific."

✅ VERIFIED (`notes/web/apple-docs-coreai.md:1043`, restated at `:1057` and again in the prose
article at `:1306`).

The prose article presents the same material as three named conditions, which is a useful mental
index (✅ VERIFIED, `notes/web/apple-docs-coreai.md:1305-1308`):

> - **OS update** — "Specialized assets are tied to the OS version. **The system always invalidates
>   assets on OS update, regardless of policy.**"
> - **Source model change** — "If the source `.aimodel` file is modified or deleted, cached assets
>   derived from it become invalid."
> - **Storage pressure** — "The system can reclaim space by deleting assets marked as purgeable."

> 🟡 **RECONSTRUCTED** — the raw composition of the two shipped policies. Given
> `PurgeConditions` is an `OptionSet` with exactly two members and given the prose above, the
> arithmetic is almost certainly
> `.default == Policy(purgeConditions: [.sourceAssetChangedOrDeleted, .storagePressure])` and
> `.persistent == Policy(purgeConditions: [])`. Apple never prints the raw values
> (`notes/web/apple-docs-coreai.md:1059`). This matters only if you construct a policy yourself —
> and there is a real use for that: `Policy(purgeConditions: [.storagePressure])` would give you
> "the system may reclaim under pressure, but a source-file change does not invalidate", which is
> exactly right for an app that rewrites metadata into its own assets. Nothing forbids it; nothing
> documents it either.
>
> **SAFE DEFAULT:** use `.persistent` or `.default` and do not construct your own until you can
> read back `purgeConditions` on device and confirm what the shipped constants contain.

### 11.3 Which policy to use

**Use `.persistent` when the specialization is expensive and re-doing it hurts the user.** That is
almost always, for anything model-sized. Every Apple sample that specializes a *downloaded* model
passes `.persistent` — the pre-specialize example, the update example, the app-group example and the
bookmark example all do (`notes/web/apple-docs-coreai.md:1312, 1332, 1358, 1378`). Follow that.

**Use `.default` when** the model is small enough that re-specialization is invisible, or when your
app has many models and you would rather the system evict the cold ones than have your app be the
reason the device is full.

⚠️ **The trap with `.persistent`** is the flip side of its guarantee. It turns off
`sourceAssetChangedOrDeleted`, which means **deleting the source file no longer reclaims the
specialization**. If you `.persistent`-specialize and then delete sources without calling
`deleteEntries(for:)` / `deleteEntry(referencedBy:)`, you accumulate orphans the system will not
clean up until the next OS update. §7.2's `reclaim(version:)` does the deletes in the right order
precisely because of this.

### 11.4 Check free space before you start

The failure mode of not doing this is documented and ugly. From the community archive, a 4B decoder
specializing on device:

> *"exhausts the device's scratch disk mid-compile → `LLVM ERROR: No space left on device`"*

Community-measured, iPhone 17 Pro / iOS 27 beta (`notes/repos/john-rocky-models.md:1108`). Note
**scratch** disk — specialization needs working space beyond the size of its inputs and outputs, and
nothing documents how much.

```swift compile:27
import Foundation

enum StorageCheck {

    /// Space the OS reports as available for "important" usage — the number that
    /// matches what a user-initiated download can actually consume.
    static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// A deliberately conservative estimate of what preparing a model needs.
    ///
    /// - the asset itself
    /// - the specialized output (unknown; budgeted at 1× the asset)
    /// - specialization scratch (unknown; budgeted at 1× the asset)
    /// - headroom so we do not fill the device to 100%
    ///
    /// 🔴 GAP: Apple publishes no figure for specialized-asset size or for
    /// specialization scratch. The 3× multiplier below is a guess chosen to be
    /// safe, not a measurement. Measure YOUR model on YOUR slowest device and
    /// replace it.
    static func estimatedRequirement(assetBytes: Int64) -> Int64 {
        assetBytes * 3 + 512 * 1024 * 1024
    }

    static func hasRoom(forAssetBytes assetBytes: Int64, at url: URL) throws -> Bool {
        try availableBytes(at: url) >= estimatedRequirement(assetBytes: assetBytes)
    }
}
```

`volumeAvailableCapacityForImportantUsageKey` is the right key rather than
`volumeAvailableCapacityKey`: it accounts for purgeable space the system would free on your behalf,
which is what actually determines whether your write succeeds. Plain Foundation, not marked.

Report the shortfall precisely — `ModelPreparationFailure.insufficientStorage(requiredBytes:
availableBytes:)` from §2.3 exists so the message can be *"Needs 5.4 GB, 2.1 GB available"* rather
than *"Not enough space."*

### 11.5 Let the user delete it

If the user opted in, the user must be able to opt out and get the storage back. The full teardown,
in the order that works:

```swift prelude:guide-context
import CoreAI
import Foundation

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct ModelUninstaller {

    /// Removes everything associated with a prepared model.
    ///
    /// ORDER IS LOAD-BEARING:
    ///   1. Drop live references, or the deletes may throw (§7.4).
    ///   2. Delete cache entries by URL, while the URL is still meaningful.
    ///   3. Delete any entry we only have a bookmark for.
    ///   4. Delete the files.
    ///   5. Delete the record.
    /// Reversing 2 and 4 orphans a multi-gigabyte specialization.
    static func uninstall(
        record: PreparedModelRecord,
        modelsRoot: URL,
        releaseLiveModels: () async -> Void
    ) async throws {

        // 1.
        await releaseLiveModels()

        let sourceURL = modelsRoot.appendingPathComponent(record.localPath)

        // 2. deleteEntries, not deleteEntry(for:options:) — removes every
        //    options variant, including any produced by a §9 divergence.
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try AIModelCache.default.deleteEntries(for: sourceURL)
        }

        // 3. Covers the case where the source was already deleted (§8.5).
        try? AIModelCache.deleteEntry(referencedBy: record.bookmark)

        // 4.
        try? FileManager.default.removeItem(at: sourceURL)

        // 5.
        UserDefaults.standard.removeObject(forKey: "model.record")
    }
}
```

There is also `deleteAll()` — *"Use this method to reclaim storage when the app no longer needs any
of its specialized models, or to reset the cache during testing"* ✅ VERIFIED
(`notes/web/apple-docs-coreai.md:1031`). It is the right call behind a "Reset AI features"
debug/settings action and the wrong call for uninstalling one model out of several.

### 11.6 Reporting storage to the user

Users find gigabytes in Settings and want to know what they are. Give them the answer inside your
app, before they go looking.

```swift prelude:guide-context
import Foundation

struct ModelStorageReport: Sendable {
    struct Item: Sendable, Identifiable {
        var id: String { name }
        var name: String
        var version: String
        var sourceBytes: Int64
        var isActive: Bool
    }
    var items: [Item]
    var totalSourceBytes: Int64 { items.reduce(0) { $0 + $1.sourceBytes } }
    var reclaimableBytes: Int64 {
        items.filter { !$0.isActive }.reduce(0) { $0 + $1.sourceBytes }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum ModelStorageAudit {

    /// Walks the versioned model root and reports what is there.
    ///
    /// ⚠️ This measures SOURCE ASSETS ONLY. The specialized assets in the Core
    /// AI cache are NOT included, because there is no API to size them — see the
    /// gap below. The number you show the user will therefore UNDER-report,
    /// often by 2× or more. Say so in the UI rather than showing a figure the
    /// user can prove wrong against Settings.
    static func audit(root: URL, activeVersion: String?) -> ModelStorageReport {
        var items: [ModelStorageReport.Item] = []
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for versionDir in versions {
            guard (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true else { continue }
            let version = versionDir.lastPathComponent
            let assets = (try? FileManager.default.contentsOfDirectory(
                at: versionDir, includingPropertiesForKeys: nil)) ?? []

            for asset in assets where AIModelAsset.isValid(at: asset) {
                let bytes = (try? bundleSizeOnDisk(at: asset)) ?? 0
                items.append(.init(name: asset.lastPathComponent,
                                   version: version,
                                   sourceBytes: bytes,
                                   isActive: version == activeVersion))
            }
        }
        return ModelStorageReport(items: items)
    }
}
```

> 🟡 **API GAP, DEVICE LOCATION MEASURED ONCE — there is no API to measure or locate the Core AI
> cache.** `AIModelCache` exposes `default`, `init?(appGroup:)`, `model(for:options:)`, four
> delete methods and the `Policy`/`PurgeConditions` types, and **nothing else** — no size property,
> no entry enumeration, no on-disk location. That is no longer just the doc index talking: the
> macOS 27.0 beta interface dump (2026-07-29) shows exactly that surface
> (✅ **SDK-verified** — `CoreAIDelegates-27.0-macos.swiftinterface:27-71`), and the `CoreAICache`
> SubFramework module — the obvious place for a richer cache API — has an **empty public Swift
> surface** in this beta (`CoreAICache-27.0-macos.swiftinterface`). A 2026-08-20 iPhone 15 Pro /
> iOS build `24A5408d` container diff narrowed the implementation: specializing a 12,288-byte toy
> model grew `Library/Caches` by 24,576 bytes, left `Library/Application Support` unchanged, and
> created `Library/Caches/coreai-cache`. That path and ratio are observations, not contracts.
>
> **What would resolve the rest:** Apple adding a size/enumeration API, plus repeated container diffs
> across realistic assets and devices. The existing result gives you a diagnostic path, not a
> supported API — do not ship code that reads it.
>
> **SAFE DEFAULT:** report source-asset sizes, which you *can* measure, and label the figure
> honestly: *"Downloaded models: 3.6 GB. Preparing a model uses additional space that iOS manages."*
> Then give the user a **Remove** button per model that runs §11.5's full teardown, so the
> unmeasurable part still gets reclaimed. A button that demonstrably frees space is worth more than
> a number that is wrong.

For calibration on how far a production app takes this: the community iOS app `noema-ios` ships a
dedicated `ModelStorageCleanup.swift`, a `ModelStorageAdvisorView`, an `InstalledModelsStore`
(a serial-queue-backed JSON store with `add/upsert/remove/reload/save` plus targeted updaters
including `updateLastUsed`), and a `rehomeIfMissing()` recovery for sandbox paths changing across
installs (community source, `notes/repos/noema-ios.md:1635, 1739, 1741, 1992`). That is the shape of
a mature answer: a store that knows what is installed, a view that explains it, a cleanup routine,
and a repair path. All four are needed once model storage is measured in gigabytes.

Two smaller patterns from the same codebase worth stealing:

- **Throttle progress updates.** `ProgressThrottler<TaskKey>(interval: 0.5)` — *"Two updates per
  second keeps progress/speed readable while preventing parallel model shards from flooding the main
  actor with dozens of callbacks per second"* (`notes/repos/noema-ios.md:1678`).
- **Verify an unload actually happened.** *"Unloading must be verified: sample `phys_footprint`
  before/after with a 500 ms settle; treat <32 MiB released as 'unchanged'"*
  (`notes/repos/noema-ios.md:2060`). The same skepticism applies to disk: after a teardown,
   re-measure rather than trusting that the delete worked — especially because §7.4's device run
   showed a live reference makes deletion throw.

### 11.7 Scheduling downloads considerately

One pattern, community-measured, that costs nothing and reads well in reviews: gate *unattended*
model downloads on charging, Wi-Fi and time of day.

```swift prelude:guide-context
// Community pattern from noema-ios (DownloadSchedulePolicy.swift).
struct DownloadSchedulePolicy {
    static let overnightStartHour = 22
    static let overnightEndHour   = 7

    static func canResumeScheduledDownloads(in e: Environment) -> Bool {
        isOvernight(e.date, calendar: e.calendar) && e.isCharging && e.isOnWiFi
    }
}
```

Community source, `notes/repos/noema-ios.md:1717-1723`. Note the scope: this gates *resuming
scheduled* downloads, not the user-initiated one from the opt-in button. A user who just tapped
"Download" expects bytes to move now, on whatever network they have. The policy is for the
background top-ups and retries.

---

## 12. The App Store reality: you cannot gate installation

### 12.1 There is no Required Device Capability for Apple Intelligence

This is the constraint that shapes the business case for the whole feature, and it is stated
plainly by an Apple Frameworks Engineer on Developer Forums thread **836810**, "Recommended App
Store distribution strategy for apps that require Foundation Models" (✅ VERIFIED,
`notes/forums/forum-pain-points.md:546-554`):

> "The recommendation on the App Store side is to provide some baseline functionality to all users,
> regardless of whether Apple Intelligence is available. **The App Store doesn't support a required
> device capability for Apple Intelligence.** Even on compatible devices, there are a number of
> reasons why Apple Intelligence could be unavailable, such as if the user selected an unsupported
> Siri language, is located in an unsupported region, or opted out of Apple Intelligence."

So: an app whose primary function needs Apple Intelligence **cannot prevent installation on
unsupported devices.** `UIRequiredDeviceCapabilities` has no key for it, and Apple's guidance is not
"use this other mechanism" — it is "design for the users you cannot exclude."

> ⚠️ **A note on this thread's status.** The brief for this guide described 836810 as *unanswered*.
> It is not: our forum capture records **five replies including two substantive Apple-staff
> answers** — the Frameworks Engineer quoted above and an Apple Designer quoted below
> (`notes/forums/forum-pain-points.md:78, 546-578`). The thread is answered; what is missing is the
> *capability*, not the answer. That distinction matters, because Apple has told you what to do
> instead, and §12.3 is that advice.

The second Apple answer in the same thread explains *why* the capability does not exist, and the
reasoning is architectural rather than an oversight (✅ VERIFIED, Apple Designer,
`notes/forums/forum-pain-points.md:556-567`):

> "As of WWDC 2026, Foundation Models framework covers both on-device foundation models and
> server-based models… _and_ both Apple Foundation Models as well as any other LLMs. So 'foundation
> models' can mean a bunch of different things and a bunch of possible models, **which is part of
> the reason why there isn't currently a clean device-capability flag.**
>
> The full list of Apple Intelligence requirements (for Apple Foundation Models) can be found here
> https://support.apple.com/en-us/121115 and include a combination of regional and hardware
> requirements.
>
> **Models from other sources can be used with Foundation Models using MLX or CoreAI, so you can
> still reach users with hardware that can't run Apple's on-device foundation model.**"

Read the last paragraph carefully, because it is Apple recommending *this guide's subject matter* as
the answer to the gating problem. Bringing your own model via Core AI or MLX is the sanctioned way
to reach devices that Apple Intelligence does not.

### 12.2 Why "compatible hardware" was never the right gate anyway

Even a hypothetical capability key would not have worked, and the Frameworks Engineer's list of
reasons is the proof. Availability depends on:

- **Hardware tier.** And it is not binary — an Apple Designer confirmed on thread 832910 that there
  are now **two** on-device models, **AFM 3 Core** and **AFM 3 Core Advanced**, split across a
  named device list with a **12 GB unified memory** floor on iPad and Mac (✅ VERIFIED,
  `notes/forums/forum-pain-points.md:274-296`). A capability flag would have had to encode a
  capability *fork*, not a boolean.
- **Siri language**, which is not the system language. Path: Settings > Apple Intelligence & Siri >
  Language (`notes/forums/forum-pain-points.md:624-625`, semi-authoritative).
- **Region.**
- **User opt-out.** A capability key cannot model a setting the user can flip after install.
- **Model download state.** The model may be downloading.

Nothing that varies at runtime can be expressed as an install-time capability. The absence is a
consequence of the design, not a gap in it.

⚠️ One related availability symptom to *not* design around: on iOS 27 betas,
`SystemLanguageModel.default.availability` has been reported returning `.appleIntelligenceNotEnabled`
unless the user has enabled Siri (forum threads 835211, 836760). **An Apple Frameworks Engineer
confirmed on thread 836760 that this is a bug** — verbatim: *"The Foundation Models framework
**should be available in Europe even if Siri AI is not enabled**. Please file a bug report via
Feedback Assistant and be sure to include a sysdiagnose to help us investigate."* ✅ VERIFIED
(`notes/forums/forum-pain-points.md:607-614`, reclassified per
`notes/CORRECTIONS-PENDING.md:10-27`). Unresolved as of 2026-07-27. Expect to hit it on betas; do
not build permanent UX around requiring Siri.

### 12.3 The four realistic strategies

**Strategy 1 — ship a baseline that works for everyone.** This is Apple's explicit recommendation:
*"provide some baseline functionality to all users, regardless of whether Apple Intelligence is
available."* Non-negotiable if your app's primary function touches AI. In practice: the app must be
useful, and reviewable, with every AI feature dark.

**Strategy 2 — bring your own model, which is the point of this guide.** Apple's own answer:
*"Models from other sources can be used with Foundation Models using MLX or CoreAI, so you can still
reach users with hardware that can't run Apple's on-device foundation model."* A Core AI feature
delivered per §§1–11 has a *different* and generally **wider** hardware envelope than Apple
Intelligence:

| | Apple Intelligence / `SystemLanguageModel` | Core AI, your model |
|---|---|---|
| Hardware | AI-capable devices only, plus a two-tier model fork | Core AI framework: **all Apple silicon**, all 27.0 platforms |
| Region / language | gated | not gated |
| User opt-out | applies | does not apply |
| AOT `.aimodelc` | n/a | **only** A17 Pro+ / M1+ / M2 Vision Pro |
| Download | OS-managed, free to you | yours (§3), 1–2 GB, your bandwidth |
| Storage | OS-managed | yours (§11) |
| Guided generation (`@Generable`) | supported | ⚠️ **not on GPU-pipelined engines** — see below |

The framework's own availability claim, from session 324: *"Core AI is available on all Apple
Silicon to help you build cutting edge AI experiences on all Apple platforms"* ✅ VERIFIED
(`notes/transcripts/coreai-intro.md:426`). Note the asymmetry in that table: the *framework* runs
broadly, the *AOT optimisation* does not. Devices outside the AOT envelope get the portable
`.aimodel` and a slower first run (§4.6) — degraded, not excluded.

⚠️ **The architectural cost of Strategy 2**, which belongs in this comparison because it is
routinely discovered too late: **grammar-constrained decoding needs access to engine logits, and
GPU-pipelined Core AI bundles never expose them.** Consequence: an app that brings its own model
**loses Apple's flagship structured-generation feature exactly when it selects the fastest
backend.** Community-measured (`notes/repos/john-rocky-models.md`, per
`notes/CORRECTIONS-PENDING.md:113-121`). This is a first-class architectural constraint, not a
footnote — factor it into the decision before you build the delivery pipeline, not after.

**Strategy 3 — check availability before anyone pays.** The Apple Designer's advice on 836810, and
the single most actionable line in the thread (✅ VERIFIED,
`notes/forums/forum-pain-points.md:571-575`):

> "Run an availability check as soon as you launch your app. … Availability can tell you additional
> information about compatibility… like if the model is downloading or not available for that
> language. From a UX standpoint, **try to check availability before anyone agrees to pay for your
> app's service, to avoid someone paying for what they can't use.**"

For a Core AI feature the equivalent check is not `SystemLanguageModel.availability` — it is
whether a compiled variant exists for `AIModel.deviceArchitectureName`, whether the portable asset
can be specialized here, and whether there is room on disk (§11.4). Run that check **before** the
paywall, and store the result so the paywall can be honest.

**Strategy 4 — fall back to a different model.** Also from the same answer: *"Figure out if you can
use a different model as backup, if Apple's on-device foundation model isn't compatible with the
device. Any server or local LLM might do."* In the 2026 architecture this is cheaper than it sounds,
because `LanguageModelSession` sits on a public `LanguageModel` protocol with several conformers —
including `CoreAILanguageModel`, which is exactly the bridge from a bundle you shipped yourself back
into the Foundation Models session API (see [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)).

### 12.4 What this means for App Review

Three concrete consequences, in the order they will bite.

**1. The reviewer's device may not be able to run your feature.** They may be on hardware, in a
region, or with a language setting that excludes Apple Intelligence — and for a Core AI feature they
will certainly be on a device where the model has to *download*, over whatever network the review
lab has, before anything works. Your first-run screen is the thing a reviewer sees. Make it
self-explanatory and make its failure states informative, because a reviewer who sees a spinner and
an unexplained failure files a rejection.

**2. Your app must be reviewable with the feature off.** Strategy 1 restated as a review
requirement. If the only path through your app runs through a 1.8 GB download, that path is a
review risk.

**3. The download itself is user-visible and needs consent.** §2's opt-in button is not only good UX;
it is the thing that makes a large transfer defensible.

Two adjacent facts worth knowing, both ✅ VERIFIED from Apple staff, because they get conflated with
the above:

- **Non-App-Store macOS apps can use the Foundation Models framework.** Frameworks Engineer, thread
  832033: *"Yes, non-App Store apps can use the Foundation Models framework to access the on-device
  system model."* (`notes/forums/forum-pain-points.md:600-602`.) Core AI has no App Store dependency
  at all — it is a framework you link.
- **Private Cloud Compute is the thing with distribution strategy attached**, not on-device
  inference. PCC eligibility requires App Store Small Business Program enrolment, fewer than
  2 million first-time downloads, and an entitlement; exceeding the threshold means *"migrate to an
  alternative solution within 6 months"* (✅ VERIFIED, `notes/forums/forum-pain-points.md:507-525`).
  If you were considering PCC as the escape hatch from the download problem, note that it has an
  eligibility cliff that on-device Core AI does not.

### 12.5 The uncomfortable summary

You cannot stop your app from being installed on a device where your AI feature will not work. You
can only:

- make sure the app is worth having anyway;
- make the feature's requirements legible **before** the user pays or waits;
- pick a delivery strategy (this guide) whose hardware envelope is wider than Apple
  Intelligence's; and
- degrade rather than fail when a device falls outside it.

That is a design constraint, not a bug, and it is stated by Apple as such. Every other approach —
detecting the device model and refusing to launch, hiding the feature behind an undocumented flag,
requiring a capability that does not exist — is a way of converting an install into a one-star
review.

---

## 13. Checklist

**Before you write any delivery code**

- [ ] Measure the `.aimodel` bundle with `bundleSizeOnDisk` (§1.2) — remember it is a *directory*
      and `skipsPackageDescendants` will silently report zero.
- [ ] Run `AIModelAsset.summary(includingStatistics: true)` and record storage types, compute types
      and function signatures (§1.1). These are your update contract (§7.3).
- [ ] Decide bundle-vs-download with the real number in front of you (§1.3).

**Delivery**

- [ ] Put a `ModelDelivery`-shaped seam between transport and Core AI (§3.4).
- [ ] Read the current Background Assets documentation before writing BA code — this guide has a
      declared gap there (§3.2).
- [ ] Store under Application Support, `isExcludedFromBackup = true`, versioned path (§3.6, §7.2).
- [ ] Commit the download only after an atomic move plus a sentinel (§3.4).
- [ ] Handle the two resume kinds correctly and expect background-created tasks to be discretionary
      (§3.5).

**Per-architecture variants**

- [ ] Ship a device diagnostic that prints `AIModel.deviceArchitectureName` and run it on every
      device family in your matrix (§5.5, layer 1).
- [ ] Never hardcode an arch code. Build asset names from `deviceArchitectureName` (§4.3).
- [ ] Pass `--architecture` explicitly or budget for ~20 macOS variants (§4.5).
- [ ] Assert the expected output path exists after every `coreai-build` invocation — the exit code
      will not tell you (§4.7, §5.1).
- [ ] **Always ship the portable `.aimodel` fallback.** Pre-A17-Pro devices get no compiled variant
      at all (§4.6).

**Specialization**

- [ ] One `SpecializationOptions` factory. Lint for it (§9.4, §9.5).
- [ ] Set `expectFrequentReshapes` explicitly — `false` for fixed-shape graphs (§5.4).
- [ ] Specialize behind the first-run screen with `.persistent`, never on first inference (§2, §6.3).
- [ ] Do not fake a specialization progress bar; there is no progress API (§6.4).
- [ ] Check free space before starting (§11.4).

**Updating**

- [ ] Delete cache entries **before** deleting or replacing files (§7.1, §7.2).
- [ ] Use `deleteEntries(for:)`, not `deleteEntry(for:options:)` (§7.1).
- [ ] Prepare the new version alongside the old; flip a pointer; reclaim later (§7.2, §7.3).
- [ ] Validate the model contract with `InferenceFunctionDescriptor` after every load (§7.3).
- [ ] Keep a rollback path (§7.5).

**Bookmarks**

- [ ] Persist a `PreparedModelRecord`, never a bare bookmark (§8.4).
- [ ] Handle the `nil` return **and** the `throw` — they are different causes with the same recovery
      (§8.2).
- [ ] Record the OS build so you can skip a doomed resolve after an update (§8.4).
- [ ] Reconsider whether deleting the source asset is worth it at all (§8.5).

**Sharing and storage**

- [ ] If you use an app group: entitlement on **every** target, one shared identifier constant, one
      shared URL resolver (§10.4).
- [ ] Never `fatalError` on a `nil` app-group cache in a shipping build — log and degrade (§10.3).
- [ ] Serialize inference in memory-constrained extensions (§10.5).
- [ ] Ship a model-storage screen with a working Remove button, and label the number honestly as
      source-assets-only (§11.6).

**Shipping**

- [ ] The app must be useful with every AI feature dark (§12.3, Strategy 1).
- [ ] Availability check before the paywall (§12.3, Strategy 3).
- [ ] Confirm whether you need `@Generable` before committing to a GPU-pipelined bundle (§12.3).

---

## 14. Declared gaps, collected

Every 🔴 GAP in this guide, in one place, with what would close it.

| # | Gap | Would be resolved by | Safe default |
|---|---|---|---|
| 1 | **The 2026 Background Assets API for Core AI.** No Apple sample, no WWDC26 transcript, no docs page shows BA delivering a `.aimodel`/`.aimodelc`. §3.2 | The WWDC25 "Discover Apple-Hosted Background Assets" transcript; the current `backgroundassets` reference; any Apple sample. `coreai` currently has **zero** sample-code projects. | Build against your own `ModelDelivery` protocol; implement with `URLSession` first. |
| 2 | **The packaging CLI for model asset packs.** Only `xcrun ba-package foundation-models package` is attested, and it is adapter-specific (adapters are discontinued in 27). §3.3 | `xcrun ba-package --help` on Xcode 27. | Do not script packaging until you have run `--help`. |
| 3 | **The `deviceArchitectureName` value set** — narrowed 2026-07-31: the compiler accepts 24 codes (`h11p…h18p`; `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`). Narrowed again 2026-08-20: a physical iPhone 15 Pro (`iPhone16,1`, `D83AP`) project-verified `h16p`; most device mappings remain community-attested and Macs remain contested (`h16c` vs `h16s`). §4.4 | Printing the property on one device per family. | Never hardcode. Derive at runtime. Always ship the portable fallback. |
| 4 | ~~**`--architecture` / `--expect-frequent-reshapes` spellings.**~~ **CLOSED 2026-07-31: both flags tool-verified via `compile --help` — `coreai-build` ships in the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`), which is why the component-less check of 2026-07-29 could not resolve it. Probing also enumerated the 24 valid `--architecture` codes (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`); the code→device mapping stays open as gap #3.** §4.2 | — | Unchanged: verify on your own machine (with the component installed) before writing a build script. |
| 5 | ~~**`AIModelError` is not documented.**~~ **CLOSED 2026-07-29 by the SDK interface dump: `AIModelError` is not public in the macOS 27.0 beta SDK; the loading APIs throw untyped; `AssetError` is the only public error type.** §5.3 | — | Do not pattern-match the private type or infer permanent incompatibility from an untyped throw. Preserve cancellation; log and rethrow unknowns. An injected incompatibility classifier must default false; keep cache repair separate and bounded. |
| 6 | ~~**Deleting an in-use cache entry: throws or defers?**~~ **CLOSED 2026-08-20 on iPhone 15 Pro / iOS build `24A5408d`: it throws while referenced, remains findable, and succeeds after release.** §7.4 | Re-run on later seeds. | Release models, delete, verify; catch generically because the observed error type is non-public. |
| 7 | ~~**No progress API for specialization.**~~ **CONFIRMED ABSENT in the macOS 27.0 beta interface (2026-07-29): the full public loading surface has no progress reporting.** §6.4 | Apple shipping one in a later release. | Indeterminate indicator plus honest text and a measured estimate. |
| 8 | **No API to size or locate the Core AI cache** — API absence remains SDK-confirmed; narrowed 2026-08-20 when a toy-model device diff observed the default cache at `Library/Caches/coreai-cache` (not a documented contract). §11.6 | Apple adding an API; repeat container diffs across realistic assets/devices. | Report source-asset sizes, label the figure honestly, ship a Remove button that reclaims the rest. |
| 9 | **Raw composition of `.default` / `.persistent` purge conditions.** 🟡 inferred from prose. §11.2 | Reading back `purgeConditions` on device. | Use the shipped constants; do not construct your own policy yet. |
| 10 | **The "(on iOS)" qualifier on `AIModelCache(appGroup:)`'s invalid-identifier case.** §10.3 | Calling it with a bogus identifier on macOS 27 and iOS 27. | Treat `nil` as the only failure signal everywhere. |
| 11 | **Specialized-asset size and specialization scratch requirements.** No Apple figure. §11.4 | Measuring your model on your slowest device. | Budget 3× the asset plus 512 MB headroom, then replace with a measurement. |
| 12 | **Whether `AIModelAsset.isValid(at:)` accepts `.aimodelc`.** Docs say "one of the known model asset extensions" without enumerating. §1.1 | Calling it on a `.aimodelc` on device. | Community usage says yes; never let `false` be the only guard before a crash. |

---

## Sources

**SDK module interfaces** (captured 2026-07-29, Xcode 27A5228h; recaptured 2026-08-20, beta 5 27A5237l, macOS 27.0 SDK;
`notes/sdk-interfaces/*-27.0-macos.swiftinterface`) — `CoreAIDelegates` (the `AIModel` loading and
`AIModelCache` surface; closed gaps #5 and #7 and confirmed the API-absence half of #8),
`CoreAIAsset` (`AssetError`), `CoreAIRuntime`, and the empty-in-this-beta `CoreAICache`. Plus the
toolchain checks: 2026-07-29, the component-less install could not resolve `coreai-build` and the
Xcode app bundle contained only `usr/bin/aimodelc`; 2026-07-31, `coreai-build 3600.79.1` found in
the Metal Toolchain component and its full
`--help` captured (`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`; closed gap #4).

**Apple documentation** (harvested 2026-07-27 via `sosumi.ai` plus Apple's raw DocC JSON API;
312-symbol index verified complete, `notes/web/apple-docs-coreai.md`)

- `documentation/coreai/` — framework page, availability
- `documentation/coreai/aimodel`, `aimodelasset`, `aimodelcache`, `specializationoptions`,
  `computeunitkind`, `inferencefunction`, `inferencefunctiondescriptor`, `asseterror`
- Article: *Integrating on-device AI models in your app with Core AI*
- Article: *Managing model specialization and caching*
- Article: *Compiling Core AI models ahead of time*
- Article: *Monitoring model performance with the debug gauge*

**WWDC26 transcripts** (`notes/transcripts/coreai-intro.md`)

- Session 324, "Meet Core AI" — specialization, the three levers, the scaling range
- Session 326, Core AI app features — the >1 GB discovery, the first-run screen, AOT, Background
  Assets, the multiplatform recipe

**Apple Developer Forums** (`notes/forums/forum-pain-points.md`) — all quoted answers carry the
Apple badge

- 836810 — no Required Device Capability for Apple Intelligence (Frameworks Engineer + Apple
  Designer)
- 829108 — adapters discontinued; "Background Assets remains a great way to deliver custom models";
  `ensureLocalAvailability(of:requireLatestVersion:)`
- 832910 — AFM 3 Core vs AFM 3 Core Advanced
- 833575 — extension memory limits and BYO models
- 836760 — the Siri-enablement availability symptom, confirmed as a bug
- 832033 — non-App-Store macOS apps
- 835897 / 833641 — PCC eligibility

**Apple shipping source** (`notes/repos/apple-coreai-models.md`,
`notes/transcripts/coreai-intro.md`)

- `apple/coreai-models` — `ModelStructure.swift:70-81` (the options profiles Apple itself picks),
  `ModelBundle.swift:122-131, 158-161` (bundle-vs-asset guards, `metadata_version`)

**Community, attributed as such throughout**

- `notes/repos/john-rocky-models.md` — AOT measurements, architecture-code validation, the
  `expectFrequentReshapes` SIGSEGV, the exit-0 finding. One engineer, one Mac (M4 Max), one iPhone
  (17 Pro), beta OSes, 2026-06-10 through 2026-07-23.
- `notes/repos/issues-coreai-stack.md` — GitHub issues on `apple/coreai-models` (#5, #27, #55, #77)
  with maintainer responses.
- `notes/repos/noema-ios.md` — a shipping iOS app's download engine, cache recovery ladder,
  architecture ranking, and storage tooling.
- `notes/web/community-blogs.md` — corroborating `coreai-build` flag observations.

**Series cross-references**

- [Part 4 — Beyond the built-in model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md) —
  `CoreAILanguageModel`, and the `@Generable` constraint from §12.3
- [Part 7 — Core AI: the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) — `AIModel`,
  `InferenceFunction`, `NDArray`, states
- [Part 8 — Core AI: converting from PyTorch](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) — producing
  the `.aimodel` this guide ships
- [Part 9 — Compression and numeric formats](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) — the other
  half of the size problem
- [Part 10 — Hardware authoring, debugging, LLM deployment](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md)
  — the Core AI instrument and debug gauge

[^phase-specific-failures]: Apple documents URL-loading failures separately from Core AI model
    specialization: [URL Loading System](https://developer.apple.com/documentation/foundation/url-loading-system),
    whose Errors topic defines `URLError`,
    and [`AIModel.specialize`](https://developer.apple.com/documentation/coreai/aimodel/specialize%28contentsof%3Aoptions%3Acache%3Acachepolicy%3A%29).
    The separate `do`/`catch` scopes preserve that API boundary in the UI state machine.

[^storage-preflight]: Apple, [`URLResourceValues.volumeAvailableCapacityForImportantUsage`](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage),
    defines the available byte count used by the preflight. Apple marks its corresponding
    [`URLResourceKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)
    as a required-reason API that must be declared in `PrivacyInfo.xcprivacy`.

[^untyped-fallback-policy]: The captured
    [`CoreAIDelegates` interface](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/sdk-interfaces/CoreAIDelegates-27.0-macos.swiftinterface)
    spells `AIModel.init(contentsOf:options:)` as `async throws` without a public typed-error
    contract; that tells a caller what can be caught by name, not why a particular operation failed.
    Apple's [*Managing model specialization and caching*](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md#delete-cached-assets-you-no-longer-need)
    deletes entries when an old source model is replaced, and the live
    [Core AI caching documentation](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching)
    gives the same lifecycle example. Swift's
    [`CancellationError`](https://developer.apple.com/documentation/swift/cancellationerror) is the
    standard signal to propagate before starting fallback work.
