# 1.2 — Every version, hardware, entitlement and runtime-surface gate

**What this covers.** Every gate that sits between the code you write and a feature that actually
runs: the four OS version floors (**26.0**, **26.2**, **26.4**, **27.0**), the Xcode/SDK split
(**Xcode 26** vs **Xcode 27**), the Apple Intelligence hardware floor (**A17 Pro / M1 / M2**), the
two on-device model tiers, per-package minimums, the `com.apple.developer.private-cloud-compute`
entitlement and the three *business* conditions behind it, the full
`SystemLanguageModel.default.availability` surface, and the places a Foundation Models call is
simply not allowed to live.

**What you need.** Nothing to read this. To *act* on it: Xcode 27 for anything marked 27.0, an
Apple-Intelligence-capable physical device (the Simulator is not a substitute — see
[§10](#10-the-simulator-trap-and-other-runtime-surfaces)), and — for Private Cloud Compute — an
approved entitlement that most established developers will not qualify for.

**Version floor for this guide.** Everything described here spans **iOS/iPadOS/macOS/visionOS
26.0 → 27.0** and **watchOS 27.0**, built with **Xcode 26.0 → 27.0**. Where a symbol landed in
**26.2** or **26.4** rather than 26.0 or 27.0, that is called out inline, because those two
mid-cycle releases are where most version confusion in the developer forums comes from. There is no
"iOS 20" and no "macOS 17" — see [§13](#13-known-bad-version-claims).

> ⚠️ **SILENT FAILURE** — this guide is *mostly* silent failures. A wrong version assumption in this
> stack does not usually produce a clear diagnostic. It produces an empty library, a `catch` block
> that stops catching, a kernel that quietly stops being compiled, a model that reports
> `isAvailable == true` and then fails with error `-1`, or a `#if` block that evaporates and takes
> your feature with it. Read the SILENT FAILURE callouts even if you skip everything else.

---

## Contents

1. [Why four floors, not one](#1-why-four-floors-not-one)
2. [The decoder ring: which API landed when](#2-the-decoder-ring-which-api-landed-when)
3. [SDK gates vs runtime gates: what `@available` cannot fix](#3-sdk-gates-vs-runtime-gates-what-available-cannot-fix)
4. [Hardware gates](#4-hardware-gates)
5. [Xcode and toolchain gates, and the known breakages](#5-xcode-and-toolchain-gates-and-the-known-breakages)
6. [Per-package requirement matrix](#6-per-package-requirement-matrix)
7. [The runtime availability surface, in depth](#7-the-runtime-availability-surface-in-depth)
8. [Entitlements and the business gates](#8-entitlements-and-the-business-gates)
9. [App Store distribution: there is no capability flag](#9-app-store-distribution-there-is-no-capability-flag)
10. [The Simulator trap, and other runtime surfaces](#10-the-simulator-trap-and-other-runtime-surfaces)
11. [A runnable preflight check](#11-a-runnable-preflight-check)
12. [What to test on](#12-what-to-test-on)
13. [Known-bad version claims](#13-known-bad-version-claims)
14. [Sources](#14-sources)

---
## 1. Why four floors, not one

Most Apple frameworks have one version floor per feature. This stack has four, and they are not
interchangeable. Here is what each one *means*, before we get to which symbols live where.

### 26.0 — "the framework exists"

The Foundation Models framework shipped in the 2025 release. Its framework-level availability line
reads:

> `iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+, macOS 26.0+, visionOS 26.0+, watchOS 27.0+ Beta`

✅ **VERIFIED** — `developer.apple.com/documentation/foundationmodels`, framework index page,
harvested 2026-07-27.

Apple's own guidance is that you never need to check for anything older:

> "Order the availability attribute from the newest version to the oldest version… **The
> availability of the Foundation Models framework starts at 26.0, so you don't need to check for
> versions prior to that.**"

✅ **VERIFIED** — `/documentation/foundationmodels/updating-prompts-for-new-model-versions`.

### 26.2 — "the Metal/hardware floor"

26.2 has nothing to do with Foundation Models. It is the floor for the **Metal Performance
Primitives TensorOps** surface — the cooperative-tensor / `matmul2d` API that both Core AI and MLX
stand on — and for Thunderbolt RDMA in MLX's distributed backend. The SDK's own availability macro
is explicit:

```c
// MPPTensorOpsAvailability.h:10  (shipped in the Xcode SDK)
#define __TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2 ((__ENVIRONMENT_OS_VERSION_MIN_REQUIRED__) >= 260200)
```

✅ **VERIFIED** — read from the `MetalPerformancePrimitives` headers in the Xcode SDK.

> ⚠️ WWDC26 session 330 describes this API as "new in iOS/macOS 27". **The header says 26.2.**
> Precedence rules put the header above the transcript, so treat 26.2 as the floor *for the base
> API*. The sliver of "27" the session got right is the newer quantized surface: the macOS 27.0
> beta SDK adds a second macro, `__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_27_0`
> (`MPPTensorOpsAvailability.h:11`, checked 2026-07-29), gating the new int2/FP4/FP8 operand
> formats and ue8m0 blockwise scale planes — those are 27.0-only. See
> [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md).

MLX's own gating agrees, in three independent places (CMake SDK version, CMake deployment target,
and a runtime `__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)`).
✅ **VERIFIED** — `mlx/backend/metal/kernels/CMakeLists.txt:158-182` and
`mlx/backend/metal/device.cpp:944-963`.

### 26.4 — "the mid-cycle model refresh"

26.4 is a *model* release as much as an API release. Apple shipped a new on-device model weight set,
reduced guardrail false positives, and added exactly two API surfaces:

| Symbol | Floor | Note |
|---|---|---|
| `SystemLanguageModel.tokenCount(for:)` | `iOS 26.4+, iPadOS 26.4+, Mac Catalyst 26.4+, macOS 26.4+, visionOS 26.4+` | ✅ **VERIFIED** — symbol page |
| `SystemLanguageModel.contextSize` | 26.0 in practice — see below | ✅ **VERIFIED** — `@backDeployed` |

`contextSize` is the interesting one, because it is the only back-deployed member in this corpus:

```swift illustrative
@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
final var contextSize: Int { get }
```

✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/contextsize`.

`@backDeployed` means the *implementation* ships in your binary for older OSes, so `contextSize` is
usable at a 26.0 deployment target once you build with an SDK that has it. `tokenCount(for:)` is
**not** back-deployed and is a hard 26.4 runtime gate.

A shipping third-party app encodes exactly this distinction in a source comment:

> "`contextSize` is available in the **Xcode 26.4+ SDK**, so it must not be hidden behind the
> Xcode 27 gate."

🟡 **RECONSTRUCTED / community source** — comment in `AFMLLMClient.swift:134-135` of the Noema iOS
app. The *observation* is correct and matches Apple's `@backDeployed` attribute; the exact SDK
minor-version claim is that developer's, not Apple's.

### 27.0 — "the framework was rebuilt"

27.0 is where the `LanguageModel` protocol, `PrivateCloudComputeLanguageModel`, Dynamic Profiles,
the new error taxonomy, Core AI, and the Evaluations framework all land — and where watchOS enters
the picture for the first time. It is also the first release where the *SDK* matters independently
of the OS, because a large block of new symbols simply does not exist in the 26 SDK. That is
[§3](#3-sdk-gates-vs-runtime-gates-what-available-cannot-fix), and it is the section that saves the
most time.

### The three model versions (not the same as the three API versions)

Apple documents the on-device model as having **three** distinct versions, which do **not** line up
one-to-one with the API floors:

> "Apple periodically updates `SystemLanguageModel` in routine OS updates… Currently there are 3
> model versions that align with:
> - iOS, iPadOS, macOS, and visionOS 26.0 - 26.3
> - iOS, iPadOS, macOS, and visionOS 26.4
> - iOS, iPadOS, macOS, visionOS, **and watchOS** 27.0"

✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel`.

So a device on 26.1 and a device on 26.3 run the *same* model; a device on 26.4 runs a different
one; a device on 27.0 runs a third. There is **no API to ask which one you got**, and no pinning
API — an Apple Frameworks Engineer confirmed both absences on the forums (thread 833642) and
recommended the Evaluations framework as the only mitigation. See
[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

---

## 2. The decoder ring: which API landed when

All availability strings below are ✅ **VERIFIED** — read off the individual symbol pages on
`developer.apple.com/documentation`, harvested 2026-07-27. Anything tagged `Beta` was still tagged
Beta at harvest time.

### 2.1 The five distinct availability strings in FoundationModels

| Availability string | What it means | Representative symbols |
|---|---|---|
| `iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+, macOS 26.0+, visionOS 26.0+` | Original 2025 release, **no watchOS, ever** | `SystemLanguageModel`, `SystemLanguageModel.UseCase`, `SystemLanguageModel.Guardrails`, `SystemLanguageModel.Availability`, `LanguageModelSession.init(model:tools:instructions:)`, `LanguageModelSession.init(model:tools:transcript:)`, `LanguageModelSession.GenerationError`, `LanguageModelSession.ToolCallError` |
| `iOS 26.0+ … visionOS 26.0+, watchOS 27.0+ Beta` | 2025 symbol that **gained watchOS in 27** | `LanguageModelSession`, `Transcript`, `Tool`, `Generable`, `GenerationSchema`, `DynamicGenerationSchema`, `GeneratedContent`, `GenerationGuide`, `GenerationID`, `Instructions`, `Prompt`, `GenerationOptions`, `GenerationOptions.SamplingMode`, `LanguageModelFeedback`, `Response`, `ResponseStream` |
| `iOS 26.4+ … visionOS 26.4+` | Mid-cycle addition | `SystemLanguageModel.tokenCount(for:)` |
| `iOS 27.0+ Beta … watchOS 27.0+ Beta` | Brand new in 2026 | everything in §2.3 |
| `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)` | Ships in *your* binary | `SystemLanguageModel.contextSize` |

<a name="22--the-watchos-contradiction-you-must-plan-around"></a>

### 2.2 ⚠️ The watchOS contradiction you must plan around

Read the first two rows again. `LanguageModelSession` is available on watchOS 27. `SystemLanguageModel`
is **not**. Neither is `SystemLanguageModel.Error`, `SystemLanguageModel.UseCase`,
`SystemLanguageModel.Guardrails`, `SystemLanguageModel.Availability`, or the two 26-era
`LanguageModelSession` initializers that are typed `model: SystemLanguageModel`.

Yet the same `SystemLanguageModel` documentation page says the third model version aligns with
"iOS, iPadOS, macOS, visionOS, **and watchOS** 27.0", and session 339 says outright:

> "Foundation Models supports **iOS, macOS, visionOS, and watchOS**, allowing developers to create a
> variety of experiences. **We recommend you try to do the same.**"

✅ **VERIFIED** as quotations — but they contradict the symbol-level availability annotation.

> 🔴 **GAP** — We cannot resolve whether `SystemLanguageModel` is genuinely absent on watchOS 27 or
> whether the documentation's availability annotation is wrong. Resolving it requires reading
> `WatchOS27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64_32-apple-watchos.swiftinterface`
> (or the `arm64e` variant) on a machine with Xcode 27, and grepping for `class SystemLanguageModel`.
> Nobody in this corpus has done that. **Until someone does, design watchOS features as if the
> on-device model may not be reachable there** — which lines up with the one thing everybody agrees
> on: `PrivateCloudComputeLanguageModel` *is* documented for watchOS 27, and session 319 explicitly
> advertises "you can even call Private Cloud Compute from watchOS."

Note also that `SpotlightSearchTool` is announced for "iOS, iPadOS, macOS, and visionOS" — watchOS
is absent from that list too (✅ **VERIFIED** — WWDC26 session 246).

### 2.3 What is hard-27.0 in FoundationModels

Everything in this list is `iOS 27.0+ Beta` (plus the sibling platforms). ✅ **VERIFIED** — each was
read from its own symbol page.

| Area | Symbols |
|---|---|
| Errors | `LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error` *(no watchOS)*, `PrivateCloudComputeLanguageModel.Error` |
| Provider protocol | `LanguageModel`, `LanguageModelCapabilities`, `LanguageModelCapabilities.Capability`, `LanguageModelExecutor`, `LanguageModelExecutorGenerationChannel`, `LanguageModelExecutorGenerationRequest` |
| PCC | `PrivateCloudComputeLanguageModel`, `.QuotaUsage`, `.Availability` |
| Dynamic profiles | `DynamicInstructions`, `DynamicInstructionsBuilder`, `DynamicInstructionsForEach`, `LanguageModelSession.DynamicProfile`, `.DynamicProfileBuilder`, `.DynamicProfileModifier`, `.Profile` |
| Session state | `LanguageModelSession.SessionProperty`, `SessionPropertyKey`, `SessionPropertyValues`, `LanguageModelSession.Usage` |
| Context / tools | `ContextOptions`, `ContextOptions.ReasoningLevel`, `TranscriptErrorHandlingPolicy`, `GenerationOptions.ToolCallingMode` |
| Images | `Attachment`, `ImageAttachmentContent`, `ImageReference` |
| Transcript | `Transcript.Reasoning`, `Transcript.AttachmentSegment`, `Transcript.ImageAttachment`, `Transcript.history`, `Transcript.structuredTranscript` |

> ⚠️ **SILENT FAILURE** — `Transcript.Reasoning` and `Transcript.AttachmentSegment` are *new enum
> payload types* on a transcript model you may already be switching over exhaustively. A 26-era
> `switch` over transcript entries or segments that compiled cleanly under Xcode 26 can start
> falling through to `default` — or fail to compile — under Xcode 27, depending on how you wrote it.
> If you wrote `@unknown default`, you get silence. Audit every exhaustive switch over `Transcript`
> types when you move SDKs. See
> [Part 17.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/01-what-changed-checklist.md).

### 2.4 The other frameworks

| Framework | Availability | Notes |
|---|---|---|
| **Core AI** | `iOS 27.0+ Beta, iPadOS 27.0+ Beta, Mac Catalyst 27.0+ Beta, macOS 27.0+ Beta, tvOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta` | ✅ **VERIFIED** — framework index. Widest platform coverage of anything here — it is the only one with **tvOS**. |
| **Evaluations** | `iOS 27.0+ Beta, iPadOS 27.0+ Beta, Mac Catalyst 27.0+ Beta, macOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta` | ✅ **VERIFIED** — framework index. Everything in it is 27.0; **Swift-only** (Apple staff, thread 833729). No tvOS. Ships **inside Xcode** like XCTest — in the Xcode 27 beta's platform `Developer/Library/Frameworks`, not in the OS SDKs (checked 2026-07-29; [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)). |
| **Speech** (baseline) | `iOS 26.0+ … tvOS 26.0+, visionOS 26.0+` | ✅ **VERIFIED**. `SpeechAnalyzer`, `SpeechTranscriber`, `AnalyzerInput`, `AssetInventory`, `SpeechDetector`. **Has tvOS.** |
| **Speech** (2026 additions) | `iOS 27.0+ Beta … tvOS 27.0+ Beta, visionOS 27.0+ Beta` | ✅ **VERIFIED**. `AnalyzerInputConverter`, `AssetInputSequenceProvider`, `CaptureInputSequenceProvider`. |
| **MetalPerformancePrimitives / TensorOps** | **26.2** (base surface) · **27.0** (int2/FP4/FP8 operands, ue8m0 scale planes) | ✅ **VERIFIED** — SDK header macros, above. Session 330's "27" is superseded for the base API; the 27.0 beta SDK's second gate covers only the new quantized formats ([Part 11 guide 1 §1.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md)). |

Two per-symbol oddities worth knowing because they will bite exactly one person on your team:

- `DictationTranscriber` has **no tvOS** (`iOS 26.0+ … visionOS 26.0+`) while `SpeechTranscriber`
  does. ✅ **VERIFIED**.
- `Transcript.structuredTranscript` omits **Mac Catalyst**:
  `iOS 27.0+ Beta, iPadOS 27.0+ Beta, macOS 27.0+ Beta, visionOS 27.0+ Beta, watchOS 27.0+ Beta`.
  ✅ **VERIFIED**.

> 🔴 **GAP** — The Core AI documentation's machine-readable `declarations` block lists
> `[iOS, iPadOS, Mac Catalyst, tvOS, visionOS, watchOS]` and **omits macOS**, even though the Core AI
> Debugger requires a macOS 27 host, `coreai-build` runs on macOS, and the Xcode debug gauge works on
> Mac. This is almost certainly a docs-generation bug and macOS 27 should be treated as supported —
> but we could not find a single *symbol* page annotated `macOS 27.0+`. Confirming it requires
> grepping the shipped `CoreAI.framework` `.swiftinterface` in the Xcode 27 macOS SDK.

---

## 3. SDK gates vs runtime gates: what `@available` cannot fix

This is the section that resolves the largest single category of confusion, so it is worth stating
the mechanic precisely before showing code.

`@available` and `if #available` are **runtime** checks. They compile a reference to a symbol into
your binary and defer the decision about whether to *execute* it. That only works if the symbol
**exists in the SDK you compiled against**. If you build with Xcode 26, the 27.0 symbols are not in
the SDK at all — there is nothing to reference, and you get `cannot find type
'PrivateCloudComputeLanguageModel' in scope`, not a graceful degradation.

So there are two orthogonal questions, and you frequently need both answers:

| Question | Mechanism | Failure mode if you get it wrong |
|---|---|---|
| Does this symbol exist in my **SDK**? | `#if canImport(FoundationModels, _version: 2)` | Hard compile error, or a silently empty module |
| Does this symbol exist on the **user's OS**? | `@available` / `if #available(iOS 27.0, …, *)` | Runtime crash (`dyld` symbol not found) |

Apple's own 2026 samples sidestep this entire section by setting a **27.0 floor**: Origami ships
`IPHONEOS_DEPLOYMENT_TARGET = 27.0`, `MACOSX_DEPLOYMENT_TARGET = 27.0`,
`XROS_DEPLOYMENT_TARGET = 27.0` and `SWIFT_VERSION = 6.0`, and contains **no `@available` or
`#available` guard anywhere in its 61 Swift files**. ✅ **VERIFIED** — `project.pbxproj` and a
whole-archive grep. If you can afford a 27.0 deployment target, that is the cheapest correct answer
to everything below. Most readers shipping into an installed base cannot, which is why the rest of
this section exists.

### 3.1 `canImport(FoundationModels, _version: 2)` — the SDK test

The only SDK-version test attested anywhere in this corpus is the one `mlx-swift-lm` uses:

```swift illustrative
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
// … the entire MLXFoundationModels adapter …
#endif
```

✅ **VERIFIED** — `ml-explore/mlx-swift-lm`, `Libraries/MLXFoundationModels`, and 37 integration-test
files. The mapping from `_version: 2` to "the 27.0 SDK" is stated in the repo's own commit message
for `3cbf928`:

> "the FoundationModels adapter (MLXFoundationModels) is gated behind
> `canImport(FoundationModels, _version: 2)` (**macOS 27 SDK only**), but the integration test files
> gated only on the always-set `FoundationModelsIntegration` trait, so they referenced symbols absent
> on the 26 SDK."

✅ **VERIFIED** — commit `3cbf928` message, "Integration tests: build on both macOS 26 and 27 SDKs (#464)".

`Package.swift:243-249` states the design intent in one sentence:

> "Public surface is gated by `@available(macOS 27 / iOS 27 / visionOS 27, *)` and
> `#if canImport(FoundationModels)`, so the target builds on every Xcode that compiles the rest of
> mlx-swift-lm."

✅ **VERIFIED** — read from `Package.swift`.

> 🔴 **GAP** — We know `_version: 2` selects the 27.0 SDK because a maintainer wrote that down. We do
> **not** know what `_version: 1` or `_version: 3` correspond to, whether the number tracks the
> framework's own module version or something else, or whether the underscored spelling is stable
> across Swift releases. Apple documents none of this. Resolving it needs either Apple documentation
> for `canImport(_:_version:)` applied to `FoundationModels`, or a matrix experiment across SDKs.
> **Do not invent a `_version: 3` for a future release.**

### 3.2 The alternative pattern: your own define

`apple/python-apple-fm-sdk` solves the same problem with a plain custom compilation condition rather
than `canImport`:

```swift illustrative
// FoundationModelsCBindings.swift:33-47
#if FM_HAS_MACOS_27_SDK
if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) {
    // attachment / image-prompt path
}
#endif
```

✅ **VERIFIED** — read from the repository. Note the shape: **both** gates, nested. `FM_HAS_MACOS_27_SDK`
is set by that package's own build script; it is not a compiler builtin. This pattern is more
portable than `canImport(_:_version:)` but shifts the detection burden onto your build system.

<a name="33--the-empty-library-failure"></a>

### 3.3 ⚠️ The empty-library failure

> ⚠️ **SILENT FAILURE** — When `#if canImport(FoundationModels, _version: 2)` is false, the guarded
> code **does not error. It ceases to exist.** `MLXFoundationModels` compiles down to an *empty
> library* on the 26 SDK. Your `import MLXFoundationModels` succeeds. Your build succeeds. The type
> you wanted is simply not there, and the diagnostic you eventually get —
> `cannot find 'MLXLanguageModel' in scope` — points at your call site, not at the SDK you are using.
> ✅ **VERIFIED** — the `FoundationModelsIntegration` trait documentation in `mlx-swift-lm`'s
> `Package.swift:44-59` describes exactly this: *"Disabling the trait compiles MLXFoundationModels to
> an empty library."*
>
> **The tell:** run `xcodebuild -version`. If it does not say `Xcode 27`, that is your bug. The
> `mlx-swift-lm` CI does precisely this check and prints
> `"FoundationModels tests will be compiled out (macOS 27 SDK required)."` when it fails.

The CI snippet is worth stealing verbatim for your own build scripts:

```bash
#!/bin/bash
# Select Xcode 27 if the machine has it; otherwise report that FM code will vanish.
# Adapted from ml-explore/mlx-swift-lm .github/workflows/integration_tests.yml:21-42
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

✅ **VERIFIED** — `.github/workflows/integration_tests.yml:21-42`.

<a name="34--the-xcode-26--27-rebuild-changes-which-catch-fires"></a>

### 3.4 ⚠️ The Xcode 26 → 27 rebuild changes which `catch` fires

This is the single most consequential SDK-version behaviour in the framework, and Apple states it in
a deprecation notice rather than a release note:

> **Deprecated**
> Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead.
> **Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You
> must update to Xcode 27 to catch the new error types before submitting your app.**

✅ **VERIFIED** — `/documentation/foundationmodels/languagemodelsession/generationerror`, which
carries `deprecated: true` in its page frontmatter.

> ⚠️ **SILENT FAILURE** — Your `catch let e as LanguageModelSession.GenerationError` block compiles
> under Xcode 27 (it is deprecated, not removed). It just never fires again, because the framework
> now throws `LanguageModelError` / `SystemLanguageModel.Error` / `LanguageModelSession.Error`
> instead. Every error path you tested becomes the `catch { }` fallthrough. There is **no compiler
> diagnostic for this** beyond a deprecation warning on a type you are still legitimately allowed to
> reference.

An Apple Frameworks Engineer posted the canonical three-arm pattern on the forums (thread 831404):

```swift compile:27
import FoundationModels

let session = LanguageModelSession()
let stream = session.streamResponse(to: "Tell me about origami.")

do {
    for try await partialResponse in stream {
        _ = partialResponse
    }
} catch let error as LanguageModelError {
    // Model-level failures: refusals, context size, unsupported locale…
} catch let error as LanguageModelSession.Error {
    // Session misuse: concurrentRequests, transcriptMutationWhileResponding
} catch let error as LanguageModelSession.GenerationError {
    // Deprecated in 27.0 — keep only while you still ship a 26-built binary
} catch {
}
```

✅ **VERIFIED** — verbatim from the Apple-staff reply in forum thread 831404. Full mapping and
migration recipe live in
[Part 17.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/references/03-error-taxonomy-migration.md).

**That pattern is missing an arm.** Apple's own shipping sample code checks
**`SystemLanguageModel.Error` first**, ahead of `LanguageModelError`, because an availability failure
is a *different type* — not a case on `LanguageModelError`:

```swift illustrative
// Error+DisplayMessage.swift — ships in Origami and, near-identically, in the Core Spotlight sample
extension Error {
    /// A short message describing the error, suitable for display in the UI.
    var displayMessage: String {
        if self is SystemLanguageModel.Error {
            return "Apple Intelligence isn't available right now."
        }
        if let modelError = self as? LanguageModelError {
            switch modelError {
            case .timeout:                      return "This is taking longer than expected…"
            case .guardrailViolation, .refusal:  return "Try a different photo or prompt."
            case .contextSizeExceeded:           return "There's too much in this conversation…"
            case .unsupportedLanguageOrLocale:   return "Origami doesn't support this language."
            default:                             break
            }
        }
        if self is GeneratedContent.ParsingError {
            return "Origami had trouble understanding the response. Please try again."
        }
        return "Something went wrong. Please try again."
    }
}
```

✅ **VERIFIED** — `Origami/Models/Error+DisplayMessage.swift:12-36`, and
`LLMSearchUsingCoreSpotlightApp/Error+DisplayMessage.swift:11-32`, which is the same file minus the
`GeneratedContent.ParsingError` clause. Two independent Apple sample projects shipping the same
taxonomy is the strongest confirmation available short of the headers. Three things to take from it:
the `default: break` means **`LanguageModelError` is non-frozen**; **`GeneratedContent.ParsingError`
is a separate type** with its own arm; and the ordering is deliberate.

> ⚠️ **SILENT FAILURE** — the Apple-staff three-arm pattern above does **not** mention
> `SystemLanguageModel.Error`, and `SystemLanguageModel.Error` is **not** reachable as a
> `LanguageModelError` case. Copy the three-arm pattern verbatim and every failure in the class
> Apple's own sample labels *"Apple Intelligence isn't available right now"* falls straight through
> to your bare `catch { }` and reaches the user as a generic "something went wrong" — the one
> category of failure they could actually have fixed themselves. Check `SystemLanguageModel.Error`
> **first**.

One platform consequence: `SystemLanguageModel.Error` is **not available on watchOS**
([§2.3](#23-what-is-hard-270-in-foundationmodels)), so the error-handling posture Apple's own samples
rely on cannot be written on watch. That compounds the watchOS ambiguity in
[§2.2](#22-️-the-watchos-contradiction-you-must-plan-around).

### 3.5 Which symbols can and cannot be papered over

| Symbol group | Papering with `@available` alone works? | Why |
|---|---|---|
| `contextSize` | ✅ Yes, even below 26.4 | `@backDeployed` |
| `tokenCount(for:)` | ✅ Yes, if you build with a ≥26.4 SDK | Runtime-only gate |
| Everything in [§2.3](#23-what-is-hard-270-in-foundationmodels) | ❌ **No** | Absent from the 26 SDK entirely |
| `MLXFoundationModels` / `MLXLanguageModel` | ❌ **No** | Compiles to an empty library on the 26 SDK |
| `CoreAILanguageModel` (`apple/coreai-models`) | ❌ **No** | Package declares `platforms: [.macOS("27.0"), .iOS("27.0")]` |
| `FoundationModelsUtilities` (Skills, history modifiers) | ❌ **No** | Package declares 27.0 across all four platforms |
| TensorOps `matmul2d` etc. | ❌ **No** | Header hard-gates on `__HAVE_TENSOR__` and a 26.2 deployment target |

---

## 4. Hardware gates

### 4.1 The Apple Intelligence floor

Apple states the hardware floor most precisely not in an Apple Intelligence document but in the
Core AI ahead-of-time-compilation article:

> **NOTE:** "Ahead-of-time compilation only compiles for devices that support Apple Intelligence,
> including **iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1 chipset or later,
> or Apple Vision Pro with the M2 chipset or later**."

✅ **VERIFIED** — `/documentation/coreai/compiling-core-ai-models-ahead-of-time`, verbatim.

That sentence does double duty. It is the Apple Intelligence hardware floor *and* the set of devices
`xcrun coreai-build compile` will emit `.aimodelc` artifacts for.

| Product line | Floor | Consequence |
|---|---|---|
| iPhone / iPad | **A17 Pro or later** | Apple Intelligence, `SystemLanguageModel`, PCC, and AOT-compiled Core AI assets |
| Mac | **M1 or later** | Same. Intel Macs are out entirely. |
| Apple Vision Pro | **M2 or later** | Same. |

> ⚠️ **SILENT FAILURE** — Devices *below* the floor get **no `.aimodelc` at all** from
> `coreai-build`. Your app does not crash; the runtime falls back to specializing the portable
> `.aimodel` on device, which is exactly the multi-second first-launch stall AOT existed to remove.
> The failure is a performance regression on old hardware that never appears in your build log. See
> [Part 7.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).

Two more things AOT does not do, both stated verbatim by Apple and both routinely misread:

> "**Even with ahead-of-time compilation, the compiled asset still requires some specialization on
> the device.** The amount of compilation that remains depends on the model and the compute units it
> uses."

> "The `specialize` method **differs from ahead-of-time compilation**. With ahead-of-time
> compilation, most of the heavy computation happens on your Mac at build time… With `specialize`,
> **the full specialization process runs on the person's device. You are controlling *when*
> specialization happens, not *reducing the work it does*.**"

✅ **VERIFIED** — both from the Core AI documentation.

> 🔴 **GAP** — The authoritative, continuously-updated list of Apple Intelligence device, region and
> language requirements is `https://support.apple.com/en-us/121115`, cited by Apple staff in at
> least three forum threads (836810, 797271, and the Python SDK README). **We did not fetch that
> page in this session.** Treat the A17 Pro / M1 / M2 line above as accurate for *chip* eligibility
> — it is quoted verbatim from Apple — but go to 121115 for the regional and language matrix, which
> changes between releases and which this guide does not reproduce.

### 4.2 Two on-device models, split by hardware tier

New in the 27 cycle: `SystemLanguageModel` is no longer one model. An Apple Designer gave the exact
device split in an accepted forum answer:

> "Yes. There is **AFM 3 Core** and **AFM 3 Core Advanced**.
>
> Previously, the same on-device model was available across all devices, with different model
> versions mentioned in the docs for `SystemLanguageModel`.
>
> Starting in the fall with Siri AI release:
>
> Devices with AFM 3 Core Advanced (most powerful):
> - iPhone Air
> - iPhone 17 Pro
> - iPhone 17 Pro Max
> - iPad (M4) or later with at least 12GB of unified memory
> - Mac (M3) or later with at least 12GB of unified memory
> - Apple Vision Pro (M5)
>
> All other devices: AFM 3 Core
>
> Plan to have different models. Model details and guidance will evolve over the summer's beta period."

✅ **VERIFIED** — Apple staff, forum thread 832910, accepted answer, quoted verbatim.

Note the **12 GB unified memory** condition on the iPad and Mac rows: an M4 iPad with 8 GB gets the
*base* model. Chip generation alone is not sufficient.

> 🔴 **GAP** — What actually differs between AFM 3 Core and AFM 3 Core Advanced is **unknown**:
> parameter count, context size, tool-calling reliability, modalities. Apple said only "plan to have
> different models… guidance will evolve." There is also **no API that tells you which tier you
> got** — consistent with there being no model-version API at all (thread 833642). Until Apple
> publishes the difference, the only defensible engineering response is to evaluate your feature on
> both tiers; see [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

### 4.3 The MLX / TensorOps hardware gate (a different floor entirely)

If you are writing MLX or Metal kernels rather than calling Foundation Models, the relevant hardware
gate is not A17 Pro — it is the neural-accelerator ("NAX") GPU generation. MLX detects it at runtime:

```cpp
// mlx/backend/metal/device.cpp:944-963
bool is_nax_available() {
#ifdef MLX_METAL_NO_NAX
  return false;
#else
  auto _check_nax = []() {
    bool can_use_nax = false;
    if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
      can_use_nax = true;
    }
    auto& d = metal::device(mlx::core::Device::gpu);
    auto arch = d.get_architecture().back();
    auto gen  = d.get_architecture_gen();
    can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
    return can_use_nax;
  };
  static bool is_nax_available_ = _check_nax();
  return is_nax_available_;
#endif
}
```

✅ **VERIFIED** — read from the MLX source. Three conditions must all hold: **OS ≥ 26.2**, **GPU
architecture generation ≥ 17** (≥ 18 for phone-class `'p'` GPUs), and the kernels must have been
compiled in at all.

> ⚠️ **SILENT FAILURE** — the compile-time half of that gate requires `MLX_METAL_VERSION >= 400`
> (Metal 4), **SDK ≥ 26.2**, *and* `CMAKE_OSX_DEPLOYMENT_TARGET >= 26.2`. Miss the deployment target
> — which a default build very often does — and CMake defines `MLX_METAL_NO_NAX`, every NAX kernel
> is dropped, and the only evidence is a CMake `message(WARNING …)` that scrolls past in a build log.
> Your code then runs correctly and slowly, forever. ✅ **VERIFIED** —
> `mlx/backend/metal/kernels/CMakeLists.txt:158-182`; two upstream PRs (#3622, #3824) exist purely
> because people hit this. Details in
> [Part 12.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/02-numerics-hardware-gating-and-custom-kernels.md).

---

## 5. Xcode and toolchain gates, and the known breakages

### 5.1 Xcode version requirements

| Thing you want to do | Minimum Xcode | Evidence |
|---|---|---|
| Call `SystemLanguageModel` / `LanguageModelSession` (26-era API) | **26.0** | ✅ WWDC26 code-along 205 and the `python-apple-fm-sdk` README both say Xcode 26.0+ |
| Read `contextSize` | **26.4 SDK** (back-deploys to older OSes) | ✅ `@backDeployed` attribute |
| Call `tokenCount(for:)` | **26.4 SDK** | ✅ symbol availability |
| Anything in [§2.3](#23-what-is-hard-270-in-foundationmodels) — PCC, Dynamic Profiles, `LanguageModel` protocol, new errors | **27.0** | ✅ symbol availability |
| Catch the new error types (i.e. any correct error handling at all in 27) | **27.0** | ✅ Apple's deprecation notice: *"You must update to Xcode 27 to catch the new error types before submitting your app."* |
| Use `apple/coreai-models` | **27.0** | ✅ repo README, "Requirements: macOS and iOS 27.0+, Xcode 27.0+" |
| Use `apple/foundation-models-utilities` | **27.0** | ✅ `Package.swift` platform floors, below |
| Build `MLXFoundationModels` non-empty | **27.0** | ✅ the `canImport(_version: 2)` gate |
| Run the Evaluations framework | **27.0** | ✅ every Evaluations symbol is 27.0 |
| Build a target containing an `.aimodel` | **27.0 + the Metal Toolchain** | ✅ Core AI docs, below |
| Use `apple/python-apple-fm-sdk` | **26.0** — genuinely *not* 27 | ✅ repo README |

### 5.2 The Metal Toolchain is not installed by default

> "Core AI model integration in Xcode requires the **Metal Toolchain, which isn't installed by
> default**. There are two options for adding the Metal Toolchain:
> - In Xcode, choose **Xcode > Settings > Components > Other Components**, then click **Get**…
> - In Xcode, select any `.aimodel` file in your project and click the **Get** button in the Metal
>   toolchain download bar that appears."

> **IMPORTANT:** "**If the Metal toolchain isn't included, builds that include `.aimodel` files fail
> with a missing Metal compiler error.**"

✅ **VERIFIED** — Core AI documentation, verbatim. From CI or a script:

```shell
xcodebuild -downloadComponent MetalToolchain
```

✅ **VERIFIED** — same doc. `mlx-swift-lm`'s own macOS CI job runs
`xcodebuild -showComponent MetalToolchain` as a precondition check, which is a reasonable pattern to
copy.

Related Xcode integration requirement, easy to miss: after adding an `.aimodel` you must see it in
the target's **Compile Sources** build phase. ✅ **VERIFIED** — Core AI docs, "After adding the file,
you should also see the model in the Compile Sources build phase for that target."

### 5.3 Core AI Debugger host requirements

- **Host machine: macOS 27 or later**
- **Paired devices: iOS 27 or later, iPadOS 27 or later, or macOS 27 or later**

✅ **VERIFIED** — `https://developer.apple.com/core-ai-debugger/`, system-requirements section.

> 🔴 **GAP** — the paired-device list contains **no visionOS, tvOS or watchOS**, even though the Core
> AI *framework* supports all three. Whether the debugger genuinely cannot attach to those platforms,
> or the download page is simply incomplete, is unknown. Nobody in this corpus has tried.

### 5.4 Known toolchain breakages

Every row here is a real, reported defect with a citable source. Status is as of **2026-07-27** —
these are beta-era problems and several may already be fixed; re-check before you route around them.

| Breakage | Symptom | Status / evidence |
|---|---|---|
| **watchOS 27 Beta 2 `FoundationModels.swiftinterface`** | `…/WatchOS27.0.sdk/…/FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15 Unable to resolve module dependency: 'CoreImage'` | ✅ **VERIFIED** — Apple Frameworks Engineer, forum thread 835987: *"This is a known bug."* No workaround given. This blocks **building for watchOS at all**, which compounds the watchOS availability ambiguity in [§2.2](#22-️-the-watchos-contradiction-you-must-plan-around). |
| **`SkillActivation` fails to build on Xcode 26** | Compilation errors when a project pulls `apple/foundation-models-utilities` | ✅ **VERIFIED** as reported — forum thread 835165; Apple asked for the specific errors and the thread was never resolved. **The mechanism is not mysterious:** the package declares 27.0 platform floors, so it cannot build against the 26 SDK. Use Xcode 27. |
| **`MLXFoundationModels` "doesn't exist"** | Developer watches session 339, sees `import MLXFoundationModels`, cannot find it in any MLX repo or branch | ✅ **RESOLVED** — it is a **library target inside `ml-explore/mlx-swift-lm`, at `Libraries/MLXFoundationModels`**, and it requires the **27.0 SDK**. Apple's forum answer (thread 836264) pointed at `mlx-swift-lm` **PR #334**; the target is now in the package's product list. If you are on Xcode 26 it compiles to an empty library — see [§3.3](#33-️-the-empty-library-failure). |
| **`ChatCompletionsLanguageModel` hardcodes `/v1`** | `HTTP error with status code 404` against any provider not on a `/v1` path (e.g. `/api/v3`) | ✅ **VERIFIED** — forum thread 838444, Apple accepted the fix (*"Fantastic suggestion, thanks! We're on it."*), FB23837262. Not a version gate, but it lives in the same package and gets misdiagnosed as one. |
| **PCC in the Simulator** | `FoundationModels.LanguageModelError Code=-1` wrapping `ModelManagerServices.ModelManagerError Code=1046` | ✅ **VERIFIED** — known issue **177684296**, documented in the iOS 27 release notes. *"Workaround: Use a physical device running OS 27.0."* See [§10](#10-the-simulator-trap-and-other-runtime-surfaces). |
| **Core AI bundles from old wheels are rejected** | `Failed to convert to versioned IR` when loading a `.aimodel` under the Xcode 27 beta 3+ SDK | ✅ **VERIFIED** — bundles must be exported with **`coreai-core >= 1.0.0b2`**; earlier wheels produce assets the newer loader rejects. FB23666783. Audit the `producer` field in your bundle's `metadata.json`. |

---

## 6. Per-package requirement matrix

The four first-party packages in this stack have **four different** version floors. This surprises
people, so it is worth stating loudly: **`python-apple-fm-sdk` still targets macOS 26**, while
`coreai-models` and `foundation-models-utilities` are hard 27.

| Package | Platform floors | Toolchain | Notes |
|---|---|---|---|
| **`apple/foundation-models-utilities`** | `.macOS("27.0")`, `.iOS("27.0")`, `.visionOS("27.0")`, `.watchOS("27.0")` — **no tvOS** | swift-tools **6.2**, `swiftLanguageModes: [.v6]` | ✅ **VERIFIED** — `Package.swift:19-22`, `:13`, `:63`. Zero dependencies. README also claims "Apple platforms and select Linux distributions like Ubuntu" — see caveat below. |
| **`apple/coreai-models`** | `.macOS("27.0")`, `.iOS("27.0")` | swift-tools **6.0**, `swiftLanguageModes: [.v6]`, `cxxLanguageStandard: .cxx17` | ✅ **VERIFIED** — `Package.swift`. README requirements section says **"macOS and iOS 27.0+, Xcode 27.0+"**. |
| **`ml-explore/mlx-swift-lm`** | `.macOS(.v14)`, `.iOS(.v17)`, `.tvOS(.v17)`, `.visionOS(.v1)` | swift-tools **6.1** | ✅ **VERIFIED** — `Package.swift:62-67`. **The package floor is low on purpose.** The FM adapter inside it is separately gated at 27.0 via the `FoundationModelsIntegration` trait plus `canImport(FoundationModels, _version: 2)`. You can use `MLXLLM` / `MLXLMCommon` / `MLXEmbedders` on macOS 14. |
| **`apple/python-apple-fm-sdk`** | macOS **26.0+**, Python **3.10+**, Apple silicon, Apple Intelligence enabled | **Xcode 26.0+**, and you must open Xcode once to accept the Xcode and Apple SDKs agreement | ✅ **VERIFIED** — `README.md:25-30`. Its embedded Swift shim declares `platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26)]`. |

### 6.1 Package-level gotchas that look like version problems

**`foundation-models-utilities` has no released 1.0.0 tag.** The README instructs consumers to write
`from: "1.0.0"`, but no non-prerelease tag exists in the repository, so that dependency **resolves to
nothing**. ✅ **VERIFIED** — repository tag list vs `README.md:30`. If SwiftPM tells you it cannot
find a version, that is why; pin a branch or a specific prerelease tag.

**`foundation-models-utilities` has no tvOS.** Deliberate or oversight, we cannot say — but if you
have a tvOS target in the same workspace, resolution will fail there.

**The Linux claim is structural, not tested.** The package genuinely contains
`#if canImport(FoundationNetworking)` and `#if canImport(Darwin)` fallbacks, and beta 3 *added*
Linux-specific code paths. But there is **no CI job, no Dockerfile and no platform matrix** anywhere
in the repository, and it requires a Linux `FoundationModels` module that is not evidenced anywhere.
🟡 **RECONSTRUCTED** — the code-level intent is verified; "it works on Linux" is not.

> 🔴 **GAP** — WWDC26 session 241 said the **core** Foundation Models framework is going open source.
> As of 2026-07-27, a search of `apple/*` and `swiftlang/*` on GitHub found only
> `foundation-models-utilities`, `python-apple-fm-sdk` and `coreai-models`. **There is no standalone
> repository for the core framework**, so on-Linux `import FoundationModels` has no visible
> implementation. Do not plan a Linux deployment on this.

**Python-side pins.** For the Core AI conversion path, the version constraint that actually bites is
not an OS version at all: **`coreai-core >= 1.0.0b2`**, because assets produced by earlier wheels are
rejected by the Xcode 27 beta 3+ SDK loader. ✅ **VERIFIED** — see [§5.4](#54-known-toolchain-breakages).
`coreai-torch` pins `coreai-core==1.0.0b2` exactly. Details in
[Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md).

---

## 7. The runtime availability surface, in depth

Everything so far was about *your build*. This section is about the device in a user's hand, where
all of your version and hardware assumptions are re-litigated at runtime.

### 7.1 `SystemLanguageModel.Availability`

```swift illustrative
@frozen enum Availability      // Equatable, Sendable, SendableMetatype
case available                 // "The system is ready for making requests."
case unavailable(_: UnavailableReason)
```

`UnavailableReason` has three documented cases: **`.appleIntelligenceNotEnabled`**,
**`.deviceNotEligible`**, **`.modelNotReady`**.

✅ **VERIFIED** — `/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum`.

Apple's own canonical switch, from the `SystemLanguageModel` class page:

```swift compile:27
import FoundationModels
import SwiftUI

struct GenerativeView: View {
    private var model = SystemLanguageModel.default

    var body: some View {
        switch model.availability {
        case .available:
            // Show your intelligence UI.
            EmptyView()
        case .unavailable(.deviceNotEligible):
            // Show an alternative UI.
            EmptyView()
        case .unavailable(.modelNotReady):
            // The model isn't ready because it's downloading or because of other system reasons.
            EmptyView()
        case .unavailable(let other):
            // The model is unavailable for an unknown reason.
            let _ = other
            EmptyView()
        }
    }
}
```

✅ **VERIFIED** — verbatim structure from Apple's documentation (the `EmptyView()` bodies and
`import` lines are ours, so this compiles as written).

Note what Apple's own sample does **not** do: it does not handle `.appleIntelligenceNotEnabled`
explicitly. That is the case you most need to handle, because it is the one the user can fix.

The two accessors on the model:

```swift compile:27 imports:FoundationModels
var isAvailable: Bool
var availability: SystemLanguageModel.Availability
```

✅ **VERIFIED** — `SystemLanguageModel` class page. `isAvailable` is the boolean convenience;
`availability` is the enum. Use `availability` in any UI that has to explain *why*. `isAvailable`
is real and used in shipping Apple sample code — `if !contentTaggingModel.isAvailable { return }`.
✅ **VERIFIED** — `FoundationModelsTripPlanner/Views/Itinerary/LandmarkDescriptionView.swift:48`.

Two initializer spellings the documentation does not lead with, both read from Apple sample code:
**`SystemLanguageModel()`** — a bare initializer, which is the 2026 house style (Origami and the
Core Spotlight sample use it exclusively and never write `.default`) — and
**`SystemLanguageModel(guardrails: .permissiveContentTransformations)`**, a `guardrails`-only form.
✅ **VERIFIED** — the bare init from `Origami/Models/OrchestratorProfile.swift:21`; the
`guardrails:` init from Book Tracker, twice, as
`LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), …)`.
Book Tracker uses `SystemLanguageModel.default` and `SystemLanguageModel()` interchangeably, so
`.default` is not deprecated — it is simply no longer what Apple reaches for first.

> 🔴 **GAP** — a third accessor, `isSupported`, is referred to in secondary summaries of this stack.
> **We could not find it on any Apple documentation page in this harvest, and it appears in none of
> Apple's five sample-code archives either.** `SystemLanguageModel`'s documented members are
> `default`, `init()`, `init(useCase:guardrails:)`, `init(guardrails:)`, `isAvailable`,
> `availability`, `contextSize`, `supportedLanguages`, `supportsLocale(_:)` and `tokenCount(for:)`
> — no `isSupported`. Do not write code against it until someone confirms it in the SDK. If you need
> "is this device capable at all, independent of user opt-in", the closest documented signal is
> `.unavailable(.deviceNotEligible)`.

#### Proactive gating or reactive catching — Apple's own code switched sides

Everything above assumes you check availability *before* showing a feature. **Apple's 2026 sample
code does not do that.** Neither Origami nor the Core Spotlight hiking-trails sample calls
`availability` or `isAvailable`, and neither carries an `#available` guard anywhere; both rely
**entirely** on catching `SystemLanguageModel.Error` at the point of use and surfacing a message.
✅ **VERIFIED** — whole-archive grep of both iOS 27 samples; see
[§3.4](#34-️-the-xcode-26--27-rebuild-changes-which-catch-fires) for the catch they use instead.

The only proactive availability switch in *any* Apple sample archive is in the coffee game, which is
an **iOS 26** project (`IPHONEOS_DEPLOYMENT_TARGET = 26.0`) that was never refreshed for 2026 — so
read it for the availability pattern, which is unchanged, and for nothing else:

```swift prelude:guide-context
// FoundationModelsCoffeeGame/MainMenu/MainMenuView.swift:47-70 — iOS 26 sample
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

✅ **VERIFIED** — quoted from the sample. Note that it *does* handle `.appleIntelligenceNotEnabled`,
which Apple's own documentation snippet above omits.

**Do both, and know why you are doing each.** They answer different questions and neither substitutes
for the other:

| | Proactive `availability` check | Reactive `SystemLanguageModel.Error` catch |
|---|---|---|
| Answers | *Should I show this feature at all?* | *Did this specific call work?* |
| Tells the user | Why, and what to change in Settings | Only that it failed, at the moment they wanted it |
| Misses | State that changes between check and call | Nothing — it is the only correctness gate |
| Apple's 2026 samples | ❌ absent | ✅ this is all they do |
| Apple's forum guidance | ✅ *"Run an availability check as soon as you launch your app"* ([§9](#9-app-store-distribution-there-is-no-capability-flag)) | — |

Apple's sample code and Apple's forum guidance point in opposite directions here, and the samples are
the weaker guide on this one point: a reader who copies Origami's posture ships an app that lets a
user reach the feature, tap it, and only then learn Apple Intelligence is off — with no route to fix
it. Gate proactively for the UX, catch reactively for correctness. That split is
[§7.6](#76-️-availability-is-not-a-promise).

### 7.2 PCC has a *different* reason set

```swift compile:27 imports:FoundationModels
let model = PrivateCloudComputeLanguageModel()

switch model.availability {
case .available:
    break
case .unavailable(.deviceNotEligible):
    // Show an alternative UI.
    break
case .unavailable(.systemNotReady):
    // PCC isn't ready to serve requests.
    break
case .unavailable(let other):
    // The model is unavailable for an unknown reason.
    _ = other
}
```

✅ **VERIFIED** — `/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute`.

`.systemNotReady` exists on `PrivateCloudComputeLanguageModel.Availability.UnavailableReason` and
**does not exist** on `SystemLanguageModel`'s. The two enums are not interchangeable, so you cannot
write one generic availability handler across both without an `@unknown default` arm. A shipping app
in this corpus does exactly that.

> 🔴 **GAP** — the **complete** case list for
> `PrivateCloudComputeLanguageModel.Availability.UnavailableReason` is unknown; only
> `.deviceNotEligible` and `.systemNotReady` were observed in documentation and shipping code.
> Always include `@unknown default`.

### 7.3 Quota is orthogonal to availability

> "A quota describes the model's **per-user request budget** and where the caller currently sits
> relative to it. **Quotas are orthogonal to a model's availability — a model can be available even
> after its usage limit has been reached.**"

✅ **VERIFIED** — Apple documentation, verbatim.

So `availability == .available` is **not** a green light to send a PCC request. You must also check
`quotaUsage`:

```swift compile:27
import FoundationModels
import SwiftUI

@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)
struct PCCQuotaBadge: View {
    let model: PrivateCloudComputeLanguageModel

    var body: some View {
        VStack {
            if model.quotaUsage.isLimitReached {
                Text("Usage limit exceeded").foregroundStyle(Color.red)
            } else if case .belowLimit(let info) = model.quotaUsage.status,
                      info.isApproachingLimit {
                Text("Nearing usage limit").foregroundStyle(Color.orange)
            }

            if let suggestion = model.quotaUsage.limitIncreaseSuggestion {
                Button("Show options") { suggestion.show() }
            }
        }
    }
}
```

✅ **VERIFIED** — the body is Apple's documentation sample; the `@available` attribute and the view
wrapper are ours. `QuotaUsage` exposes `isLimitReached`, `status`, `resetDate` and
`limitIncreaseSuggestion`. `resetDate` is documented as *"empty when the reset date isn't known or
when the person is well below their limit."*

> 🔴 **GAP** — the full case list of `QuotaUsage.Status` is unverified; only `.belowLimit(_:)` was
> observed. Developers on the forums have asked for actual numbers rather than the three coarse
> states (FB23378161); Apple has not shipped that.

### 7.4 The Siri-toggle coupling — an acknowledged defect, not a gate

This is the finding that produces the most phantom bug reports on 27 betas. It is **a bug, not a
design** — but it is an *unfixed* bug, so you will still hit it, and you still have to handle it.

**Thread 835211** (unanswered, 2026-06-18): on iOS 27 beta 1,
`SystemLanguageModel.default.availability` returns **`.appleIntelligenceNotEnabled`** unless the user
has enabled **"Siri" / "Hey Siri"** or **"Press Side Button for Siri"**. The developer's title states
it as a question — *"Why is `SystemLanguageModel.default.availability` tied to user enabling talk /
press side button for Siri?"* — and it received zero replies.

**Thread 836760** (2026-07-02) reports the same behaviour on macOS from beta 2 — "Foundation models
are not accessible if Siri AI is not enabled" — and raises the obvious **EU** concern, since Apple
Intelligence and Siri features have shipped on different schedules there. An Apple Frameworks
Engineer replied:

> "The Foundation Models framework **should be available in Europe even if Siri AI is not enabled**.
> Please file a bug report via Feedback Assistant and be sure to include a sysdiagnose to help us
> investigate."

✅ **VERIFIED** — both threads captured verbatim.

That reply does two things at once, and the second is the load-bearing one. **"Should be available"**
states the *intended* design: Foundation Models is not meant to be coupled to the Siri toggle.
**"File a bug report… include a sysdiagnose to help us investigate"** is what Apple asks for when it
intends to chase a **defect** — nobody requests a sysdiagnose about behaviour that is working as
designed. Taken together with two independent reports on two platforms, the coupling is
**unintended**. Design accordingly: this is a beta defect to route around, **not** a permanent
constraint to build product around. Do not ship UX that tells users they must turn Siri on.

Note carefully what the reply does *not* say, because the difference decides how long you carry a
workaround. It does not use the words *"this is a known bug"* — the phrasing an Apple engineer
**did** use about the watchOS build break in thread 835987 ([§5.4](#54-known-toolchain-breakages)).
It cites no known-issue number. And it answers a question scoped to **Europe**. Stating intent and
asking for a sysdiagnose is one step short of Apple confirming it has reproduced the defect.

> 🔴 **GAP** — The coupling is acknowledged as unintended; **whether it is fixed, and on which build,
> is unknown as of 2026-07-27**. There is no known-issue number, no release-note entry, no follow-up
> on 835211, and no report of a beta on which the behaviour stopped. Resolving it needs a controlled
> test on a current beta with Siri fully disabled, or a release-notes entry. **Practical advice in
> the meantime:** handle `.appleIntelligenceNotEnabled` with a user-actionable message and expect it
> on 27 betas even from users who have Apple Intelligence switched on; if you ship in the EU, test
> with Siri disabled explicitly. Treat any workaround you build as temporary and delete-able.

### 7.5 Language and locale gating follows *Siri's* language

Availability is not only hardware and opt-in. The model is gated on language too, and the language
it reads is **not** the system language.

```swift illustrative
final var supportedLanguages: Set<Locale.Language> { get }
final func supportsLocale(_ locale: Locale = Locale.current) -> Bool
```

✅ **VERIFIED** — `SystemLanguageModel` class page. Apple's guidance on which to use:

> "Use this method over `supportedLanguages` to check whether the given locale qualifies a user for
> using this model, as this method will take into consideration **language fallbacks**."

✅ **VERIFIED**. The practical consequence, reported on the forums, is that `supportsLocale(_:)`
returns `true` for a *close* language — a user set to Catalan qualifies because Spanish is supported.
🟡 **RECONSTRUCTED** — that specific example comes from a forum reply whose Apple-staff status is
ambiguous; the "language fallbacks" mechanism itself is verified from Apple's own prose.

An Apple Frameworks Engineer on the framing:

> "Foundation Models support the same set of languages as Apple Intelligence."
> → `https://support.apple.com/en-us/121115`

✅ **VERIFIED** — forum thread 797271.

Two consequences worth designing for:

- The setting a user changes is **Settings > Apple Intelligence & Siri > Language**, not the device
  language. 🟡 **RECONSTRUCTED** — reported in thread 805378 by an account whose Apple status could
  not be confirmed; consistent with everything Apple says, but the exact Settings path is not
  Apple-sourced here.
- There is **no per-session language override**. A developer explicitly requested
  `LanguageModelSession(preferredLanguage: "es-ES")`; it does not exist. ✅ **VERIFIED** as a
  request, not a shipped API — thread 805378.

Apple also documents that *all* model input must be in a supported language, including your Swift
type and property names:

> "***all* inputs need to be in supported language for the model to understand, including all
> `Generable` types and descriptions.**"
> "Because the framework treats `Generable` types as model inputs, **the names of properties like
> `age` or `profile` are just as important as the `@Guide` descriptions**."

✅ **VERIFIED** — `/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models`.

<a name="76--availability-is-not-a-promise"></a>

### 7.6 ⚠️ Availability is not a promise

> ⚠️ **SILENT FAILURE** — `model.isAvailable` returning `true` does **not** mean a request will
> succeed. Forum thread 831998 documents a case where `isAvailable == true` and the call still fails
> with `FoundationModels.LanguageModelError Code=-1` wrapping an undocumented
> `ModelManagerServices.ModelManagerError Code=1046`. A second developer reproduced the same `-1` on
> a **physical iPhone 17 Pro Max with New Siri enabled**, so this is not simulator-only. There is no
> availability state that predicts it. ✅ **VERIFIED** — thread 831998, quoted error verbatim.
>
> **Design rule:** treat availability as a *UI gate* (should I show this feature?) and error handling
> as the *correctness gate* (did this call work?). Never use availability as a substitute for a
> `do/catch`.

An Apple Designer's framing of what availability is for, from the distribution-strategy thread:

> "Run an availability check as soon as you launch your app… From a UX standpoint, **try to check
> availability before anyone agrees to pay for your app's service**, to avoid someone paying for what
> they can't use."

✅ **VERIFIED** — forum thread 836810.

---

## 8. Entitlements and the business gates

### 8.1 On-device Foundation Models: no entitlement, no limits

There is no entitlement for `SystemLanguageModel`. A DTS Engineer stated plainly that on-device
Foundation Models have **no limits** for any developer (thread 835897), and a Frameworks Engineer
confirmed that **non-App-Store, notarized macOS apps can use it**:

> "Yes, non-App Store apps can use the Foundation Models framework to access the on-device system
> model."

✅ **VERIFIED** — forum thread 832033.

### 8.2 Private Cloud Compute: three conditions, and two of them are commercial

This is the gate that stops most readers, and it is not technical. Verbatim from
`https://developer.apple.com/private-cloud-compute/`:

> Access to PCC is available to developers who meet the following criteria:
> - Are enrolled in the **App Store Small Business Program**.
> - Have **fewer than 2 million first-time app downloads** from any of their apps on the App Store.
> - Have the **Private Cloud Compute entitlement** assigned to their account.

✅ **VERIFIED** — fetched from the live page. And the consequences of crossing the line:

> "If any app subsequently exceeds the 2 million first-time downloads threshold, or the developer is
> no longer enrolled in the App Store Small Business Program, the developer will be notified and must
> **migrate to an alternative solution within 6 months**."

> "Where Apple Intelligence is available, eligible developers can use PCC in their apps distributed
> on the App Store, and test PCC features via TestFlight or ad hoc distribution. **Installs during
> testing are not counted as first-time app downloads.**"

✅ **VERIFIED** — same page. A Frameworks Engineer restated the 6-month migration window in thread
833641.

**The download threshold is cumulative, not annual.** A developer in thread 835897 with ~180k units
in the last year is ineligible because of pre-2015 success. A DTS Engineer confirmed the reading:
apps with more than 2 million first-time downloads **across a long time span** are ineligible.
✅ **VERIFIED** — thread 835897.

> ⚠️ **The Small Business Program condition needs one more confirmation before you plan around it.**
> 🟡 **RECONSTRUCTED (policy, high confidence).** It appears on the developer-site eligibility page
> quoted above and in secondary coverage, and it was announced at the Platforms State of the Union
> on **9 June 2026** — but it is **stated in no WWDC session transcript in this corpus**. Sessions
> 241 and 319 mention only the download threshold: session 319 says *"This model is available for
> apps with less than 2M downloads"* and nothing about the Small Business Program. That omission is
> material, because a developer can clear the download bar and still be ineligible. Before you build
> a product plan on it, confirm directly on the entitlement application page.

**URL correctness matters here.** `https://developer.apple.com/apple-intelligence/private-cloud-compute/`
**404s**. The live path is `https://developer.apple.com/private-cloud-compute/`. ✅ **VERIFIED** —
both checked. The entitlement request form is at `/contact/request/private-cloud-compute/`, and the
same request can be initiated from the bottom of the "Adding server-side intelligence with Private
Cloud Compute" documentation page. One developer reported the request page returning **HTTP 500**
during WWDC26 week, so if it fails, try the doc-page route.

### 8.3 The PCC entitlement itself

**`com.apple.developer.private-cloud-compute`** — a **managed** entitlement, meaning it must be
requested and granted; you cannot simply add the key to your `.entitlements` file and build.

✅ **VERIFIED** — the entitlement is listed in the FoundationModels framework index under "Private
Cloud Compute", documented at
`/documentation/BundleResources/Entitlements/com.apple.developer.private-cloud-compute`, described as
"managed" in Apple's own article prose, and present in four shipping `.entitlements` files in a
third-party app in this corpus.

An Apple Designer disambiguated the two things people confuse:

> "The entitlement **application** is what you need to 'apply' for the program, and this entitlement
> **in Xcode** is what allows your app to access PCC."

✅ **VERIFIED** — forum thread 834749, accepted answer.

Apple's own sample code shows the shape this implies: **ship on-device by default and make PCC a
one-line swap.** Origami stores the model as a stored property of its profile and leaves the PCC line
commented out:

```swift compile:27 imports:FoundationModels
// Origami/Models/OrchestratorProfile.swift:14-21
// Brainstorm and tutorial work best on a server model. The sample
// defaults to the on-device system model so it runs out of the box.
// To use Private Cloud Compute, request access to the managed
// `com.apple.developer.private-cloud-compute` entitlement at
// https://developer.apple.com/contact/request/private-cloud-compute/,
// then replace the `serverModel` initialization with the line below.
// var serverModel = PrivateCloudComputeLanguageModel()
var serverModel = SystemLanguageModel()
```

✅ **VERIFIED** — quoted verbatim; the same comment block appears byte-for-byte in the Core Spotlight
sample. `Origami/Origami.entitlements` contains **only** `com.apple.security.app-sandbox`. Apple
shipping its flagship Foundation Models sample *without* the PCC entitlement independently confirms
both that the entitlement is managed and that a sample is expected to run without it — and it is the
right defensive shape given the `fatalError` below.

Because the model is a stored property rather than a per-branch choice, the profile can ask which
backend it actually got:

```swift prelude:guide-context
private var isOnDevice: Bool {
    type(of: serverModel) == SystemLanguageModel.self
}
```

✅ **VERIFIED** — `Origami/Models/OrchestratorProfile.swift`. This is Apple's own idiom for a runtime
model-*kind* test, and the closest thing to an API for "which backend am I talking to". It is **not**
a model-*tier* test: it cannot tell you AFM 3 Core from AFM 3 Core Advanced, and nothing can — see
[§4.2](#42-two-on-device-models-split-by-hardware-tier).

> ⚠️ **SILENT FAILURE — except it isn't silent, it's fatal.** Removing the Private Cloud Compute
> entitlement while your code still constructs a `PrivateCloudComputeLanguageModel` triggers a
> **`fatalError`** at runtime. Not a thrown error you can catch — a crash. ✅ **VERIFIED** — reported
> in forum thread 831998. Gate PCC construction behind both `#available` **and** a build
> configuration that matches your provisioning profile.

### 8.4 Other entitlements in the neighbourhood

| Entitlement | What it is for | Status |
|---|---|---|
| `com.apple.developer.private-cloud-compute` | PCC access | ✅ **VERIFIED**, managed, see above |
| `com.apple.developer.foundation-model-adapter` | Shipping a custom LoRA adapter, on the app **and** its asset-downloader extension | ✅ **VERIFIED** — forum thread 823148. **Historical: adapters are discontinued in OS 27**, confirmed twice by Apple staff (threads 829108, 831314). Relevant only if you still ship a 26.x build. |
| `continued-processing.gpu` | Background GPU work | 🟡 **RECONSTRUCTED** — named by a developer in thread 833666 and not disputed by the Apple reply; the exact full entitlement key was not captured. |
| *An entitlement for `SpotlightSearchTool`* | Letting a `LanguageModelSession` search the Core Spotlight index | ❌ **None required.** Apple's Core Spotlight sample ships an `.entitlements` file containing an empty `<dict/>`. ✅ **VERIFIED** — `LLMSearchUsingCoreSpotlightApp`. See [Part 2.4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md). |
| *An NPU-priority entitlement* | Preventing the OS preempting your on-device inference in the background | ❌ **Does not exist.** Apple Frameworks Engineer: *"The OS manages the requests for the on-device LLM automatically, based on the system conditions (like thermals). **There's no entitlement or API to influence this.**"* ✅ **VERIFIED** — thread 833666. |

---

## 9. App Store distribution: there is no capability flag

If your app's *primary* function is a Foundation Models feature, you cannot stop it being installed
on a device that cannot run it. This is stated by Apple, not inferred:

> "The recommendation on the App Store side is to provide some baseline functionality to all users,
> regardless of whether Apple Intelligence is available. **The App Store doesn't support a required
> device capability for Apple Intelligence.** Even on compatible devices, there are a number of
> reasons why Apple Intelligence could be unavailable, such as if the user selected an unsupported
> Siri language, is located in an unsupported region, or opted out of Apple Intelligence."

✅ **VERIFIED** — Apple Frameworks Engineer, forum thread 836810.

An Apple Designer in the same thread explained *why* the flag does not exist, and the reasoning is
the structural change this whole series is about:

> "As of WWDC 2026, Foundation Models framework covers both on-device foundation models and
> server-based models… _and_ both Apple Foundation Models as well as any other LLMs. So 'foundation
> models' can mean a bunch of different things and a bunch of possible models, which is part of the
> reason why there isn't currently a clean device-capability flag.
>
> Models from other sources can be used with Foundation Models using **MLX or CoreAI**, so you can
> still reach users with hardware that can't run Apple's on-device foundation model."

✅ **VERIFIED** — same thread. The recommended two-step response, quoted:

1. "Run an availability check as soon as you launch your app… **try to check availability before
   anyone agrees to pay for your app's service**."
2. "Figure out if you can use a different model as backup, if Apple's on-device foundation model
   isn't compatible with the device. **Any server or local LLM might do.**"

Note that thread 836810's original question — what the recommended App Store *distribution strategy*
is for an app that genuinely cannot function without Foundation Models — never got a satisfying
answer. Developers are visibly unhappy about it.

> 🔴 **GAP** — There is no `UIRequiredDeviceCapabilities` value, no `MinimumOSVersion` trick, and no
> App Store Connect setting that filters for Apple Intelligence. If one ships, it will be announced;
> as of 2026-07-27 the Apple position is "build a baseline experience". **Do not invent an
> `Info.plist` key for this.** The architectural answer is a fallback backend — Core AI, MLX, or a
> remote model behind the `LanguageModel` protocol. See
> [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md).

---

## 10. The Simulator trap, and other runtime surfaces

### 10.1 The Simulator punches out to the host Mac

This is the single largest generator of phantom bug reports in the corpus. The explanation is an
Apple Designer's accepted answer in thread 831404, and it is worth reading twice:

> "Xcode 27.0 contains the latest SDK, but the on-device `SystemLanguageModel` is actually **built
> into the OS**. **Meaning** that when you run simulator from Xcode, the simulator is actually
> **'punching out' to macOS** to run the model, using the 26.5 model inference code in the OS.
> Whenever we see 'weird' errors like this, it's usually an underlying incompatibility between the
> Xcode SDK and OS for running the model. :(
>
> **Suggested Fix** Update a physical device to 27.0."

✅ **VERIFIED** — forum thread 831404, verbatim.

So: **Xcode 27 SDK + macOS 26 host = the simulator runs the macOS 26 model behind a 27 API surface.**
The errors this produces are generic `-1`s with no useful underlying information, and they look
exactly like framework bugs. A DTS Engineer in thread 837226 gave the same advice in different words:
*"Apple Intelligence and the `FoundationModels` framework rely heavily on on-device hardware."*

### 10.2 What does and does not work where

| Surface | On-device `SystemLanguageModel` | PCC | Evidence |
|---|---|---|---|
| Physical device, OS 27 | ✅ | ✅ | — |
| Simulator on a macOS **27** host | ⚠️ Works, but runs the host's model | ❌ **Broken** | ✅ known issue **177684296**, iOS 27 release notes |
| Simulator on a macOS **26** host | ⚠️ Meaningless `-1` errors | ❌ | ✅ thread 831404 |
| App extension (non-XPC-restricted) | ✅ **and it does not count against your extension's memory limit** | 🔴 unknown | ✅ thread 833575 |
| XPC-restricted extension | ❌ **Cannot use the framework at all** | ❌ | ✅ thread 833575 |
| Background execution | ⚠️ OS-throttled; no priority control | ⚠️ | ✅ thread 833666 |
| Shortcuts "Use Model" action | ⚠️ Works, but **errors cannot be detected** | ⚠️ | ✅ thread 813757 |
| `WKWebView` / JavaScript | ❌ no JS interface; bridge via `WKUserContentController` | ❌ | ✅ thread 833716 |
| Notarized (non-App-Store) macOS app | ✅ | 🔴 unknown | ✅ thread 832033 |
| watchOS 27 | 🔴 see [§2.2](#22-️-the-watchos-contradiction-you-must-plan-around) | ✅ documented, and PCC on watchOS was explicitly advertised in session 319 | mixed |

The extension memory point is worth pulling out because it is a genuine architectural advantage:

> "The system language model (`SystemLanguageModel`) is **not loaded into the app / extension's
> memory**, and so using it **doesn't count on the memory limit of your extension**. If you are using
> your own on-device model, the model will be loaded to the memory of your app / extension… **Note
> that some extensions don't allow XPC due to privacy reason, and hence can't use a model via the
> Foundation Models framework.**"

✅ **VERIFIED** — DTS Engineer, forum thread 833575.

> 🔴 **GAP** — Which specific extension points are XPC-restricted, and therefore cannot use
> Foundation Models, is **not enumerated anywhere**. The original question in thread 833575 was
> specifically about `MessageFilterExtension`, and the follow-up — *"Does this include
> `SystemLanguageModel`?"* — was never answered. There is an open feature request (thread 810398) to
> allow Foundation Models in MessageFilter extensions, which implies it currently cannot. Test your
> specific extension point empirically.

> 🔴 **GAP** — whether PCC works for non-App-Store macOS distribution is unresolved. Thread 832033
> confirms on-device works; the PCC eligibility page's wording ("distributed on the App Store… test
> via TestFlight or ad hoc") implies App Store distribution is required, but does not say so about
> notarized Mac apps directly.

### 10.3 watchOS + PCC needs a paired iPhone

A developer's own answer, unconfirmed by Apple but high-signal:

> "No, not only does the Watch have to be running WatchOS 27, it also needs to be paired to an iPhone
> with Apple Intelligence enabled. This is despite the fact that PCC queries from WatchOS 27 go
> straight to the server and don't require the paired iPhone at all 🤷‍♂️"

🟡 **RECONSTRUCTED** — forum thread 834652; the OP answered their own question and no Apple reply
followed. If true, the practical rule is **Apple Watch Series 11 + iPhone 15 = no PCC**. Test it
before shipping a watch-first feature.

---

## 11. A runnable preflight check

The following compiles against the **27.0 SDK** and degrades on older SDKs and older OSes. It is
deliberately structured to separate the four questions this guide has been about: *does the symbol
exist in my SDK*, *does it exist on this OS*, *is the feature available on this device right now*,
and *did the call actually work*.

```swift compile:26,27 defines:PCC_ENABLED
// AIPreflight.swift
// Requires: Xcode 27 (27.0 SDK). Compiles — with reduced functionality — on the 26 SDK.
// Define PCC_ENABLED only in targets whose signed product carries the managed
// com.apple.developer.private-cloud-compute entitlement.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the app should offer this user, right now.
public enum AICapability: Sendable, Equatable {
    case onDeviceAndCloud
    case onDeviceOnly
    case cloudOnly
    /// Nothing Apple provides is usable. Fall back to your own backend, or hide the feature.
    case none(reason: String)
}

public enum AIPreflight {

    public static func evaluate(locale: Locale = .current) -> AICapability {
        #if canImport(FoundationModels)
        let onDevice = onDeviceState(locale: locale)
        #if PCC_ENABLED && canImport(FoundationModels, _version: 2)
        let cloud    = cloudState()
        #else
        let cloud: State = .blocked("PCC is not enabled for this build and SDK.")
        #endif

        switch (onDevice, cloud) {
        case (.ready, .ready):
            return .onDeviceAndCloud
        case (.ready, .blocked):
            return .onDeviceOnly
        case (.blocked, .ready):
            return .cloudOnly
        case (.blocked(let onDeviceReason), .blocked(let cloudReason)):
            return .none(reason: "on-device: \(onDeviceReason); cloud: \(cloudReason)")
        }
        #else
        return .none(reason: "Built without the FoundationModels framework.")
        #endif
    }

    // MARK: - internals

    private enum State {
        case ready
        case blocked(String)
    }

    #if canImport(FoundationModels)
    private static func onDeviceState(locale: Locale) -> State {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            // User-actionable. Note the beta-era Siri defect described in §7.4:
            // on 27 betas this also fires when Siri itself is switched off, even
            // though Apple says it should not. Word your message so it still makes
            // sense to a user who has Apple Intelligence on and Siri off.
            return .blocked("Apple Intelligence is turned off in Settings.")
        case .unavailable(.deviceNotEligible):
            return .blocked("This device can't run Apple Intelligence.")
        case .unavailable(.modelNotReady):
            // Transient: downloading, or the system is busy. Retry later; do not
            // present this as a permanent failure.
            return .blocked("The model isn't ready yet.")
        case .unavailable(let other):
            // `Availability` is documented `@frozen` with exactly two cases, so
            // this arm — not an `@unknown default` — is the catch-all here.
            return .blocked("Unavailable: \(String(describing: other))")
        }

        // Availability being `.available` says nothing about language support.
        guard model.supportsLocale(locale) else {
            return .blocked("The model doesn't support \(locale.identifier).")
        }
        return .ready
    }
    #endif

    #if PCC_ENABLED && canImport(FoundationModels, _version: 2)
    private static func cloudState() -> State {
        // Hard 27.0 SDK symbols. The surrounding versioned canImport condition
        // removes this entire function from SDK-26 builds (see §3.1).
        guard #available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) else {
            return .blocked("Private Cloud Compute requires OS 27.")
        }

        // Constructing this type without the granted entitlement is fatal at
        // runtime (§8.3); the surrounding PCC_ENABLED gate is the safety boundary.
        let model = PrivateCloudComputeLanguageModel()

        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            return .blocked("This device can't use Private Cloud Compute.")
        case .unavailable(.systemNotReady):
            return .blocked("Private Cloud Compute isn't ready to serve requests.")
        case .unavailable(let other):
            return .blocked("PCC unavailable: \(String(describing: other))")
        @unknown default:
            // PCC's Availability is NOT documented as `@frozen`, and its complete
            // reason list is unverified (§7.2), so keep this arm. If the type turns
            // out to be frozen, the compiler will warn that it is unreachable —
            // a warning is the cheaper failure here.
            return .blocked("PCC unavailable for an unrecognised reason.")
        }

        // Quota is orthogonal to availability (§7.3).
        if model.quotaUsage.isLimitReached {
            return .blocked("Daily Private Cloud Compute quota reached.")
        }
        return .ready
    }
    #endif
}
```

Three things this snippet is deliberately doing, each corresponding to a trap above:

1. **`#if canImport(FoundationModels)` wraps the import, not just the call sites.** The PCC path has
   two additional compile-time gates: `PCC_ENABLED` proves this signed target carries the managed
   entitlement, and `canImport(FoundationModels, _version: 2)` excludes the 27-only PCC surface from
   SDK-26 builds. The fence is verified against both SDK generations
   ([§3.1](#31-canimportfoundationmodels-_version-2--the-sdk-test)).
2. **`@unknown default` on the PCC switch, but not the on-device one.**
   `SystemLanguageModel.Availability` is documented `@frozen`, so `case .unavailable(let other)`
   is already the exhaustive catch-all and an `@unknown default` would be dead code.
   `PrivateCloudComputeLanguageModel.Availability` is *not* documented as frozen and its complete
   reason list is unverified ([§7.2](#72-pcc-has-a-different-reason-set)) — a shipping third-party
   app in this corpus writes it the same way.
3. **`.modelNotReady` is treated as transient.** It is the "downloading or system busy" case, and
   presenting it as "your device can't do this" is a common and user-hostile mistake.

> ⚠️ **SILENT FAILURE** — this preflight returns `.onDeviceOnly` or `.cloudOnly`; it does **not**
> guarantee a request will succeed ([§7.6](#76-️-availability-is-not-a-promise)). Wrap every actual
> `respond` call in the three-arm `catch` from
> [§3.4](#34-️-the-xcode-26--27-rebuild-changes-which-catch-fires).

---

## 12. What to test on

Version confusion is cheap to eliminate if you own the right hardware and expensive to debug if you
do not. This is the minimum honest matrix.

### 12.1 Devices

| Tier | Device | Why you need it |
|---|---|---|
| **Must have** | An iPhone on **iOS 27** that is **not** in the AFM 3 Core Advanced list (e.g. an iPhone 16 or a non-Pro 17) | This is the base on-device model most of your users get. |
| **Must have** | An **AFM 3 Core Advanced** device — iPhone Air, iPhone 17 Pro, or 17 Pro Max | The capability fork is real and undocumented; you cannot infer one tier's behaviour from the other. |
| **Must have** | A Mac on **macOS 27** | Both as a host (the Simulator punches out to it) and as a target. |
| **Should have** | A device on **iOS 26.4** | The 26.4 model is a *different model* from both 26.0-26.3 and 27.0, and it is where `tokenCount(for:)` first appears. |
| **Should have** | A device on **iOS 26.0-26.3** if you still support it | Third distinct model. Also the only place `GenerationError` is not deprecated. |
| **Should have** | A device **below the Apple Intelligence floor** (pre-A17 Pro iPhone, Intel Mac) | To exercise `.unavailable(.deviceNotEligible)` and your fallback path — which the App Store requires you to have ([§9](#9-app-store-distribution-there-is-no-capability-flag)). |
| **If shipping watchOS** | Apple Watch on **watchOS 27**, paired with an Apple-Intelligence-capable iPhone | Both the framework build break ([§5.4](#54-known-toolchain-breakages)) and the PCC pairing question ([§10.3](#103-watchos--pcc-needs-a-paired-iphone)) live here. |
| **If shipping Core AI** | One device per architecture you emit `.aimodelc` for | `coreai-build` produces `MyModel.<arch>.aimodelc` per architecture, and each device uses exactly one. ✅ **VERIFIED** — Core AI docs. |

### 12.2 Configurations to exercise deliberately

Each of these corresponds to a documented failure mode, not a hypothetical:

- **Apple Intelligence toggled off** in Settings → `.unavailable(.appleIntelligenceNotEnabled)`.
- **Siri disabled entirely** (including "Press Side Button for Siri") → the acknowledged-as-unintended
  coupling in [§7.4](#74-the-siri-toggle-coupling--an-acknowledged-defect-not-a-gate). Apple says
  this should not happen; on 27 betas it does. If you ship in the EU, this is not an edge case.
- **A Siri language your app does not support** → `supportsLocale(_:)` false, and
  `LanguageModelError.unsupportedLanguageOrLocale`.
- **Airplane mode** → PCC fails; Apple's documented instruction is *"if the request fails because the
  network connection is unavailable, retry the request using the on-device model."* ✅ **VERIFIED**.
- **PCC quota exhausted** → simulate it from Xcode rather than burning a real quota:
  > 1. Choose **Product > Scheme > Edit Scheme**.
  > 2. Select the **Run** page and choose the **Options** tab.
  > 3. Select either **"Approaching Quota Usage Limit"** or **"Quota Usage Limit Reached"** from the
  >    **"Simulated Apple Foundation Models Availability"** drop-down menu.
  > 4. Click Close and run your project.

  ✅ **VERIFIED** — Apple documentation, verbatim. Note that WWDC26 session 319 narrates this menu
  with **different strings** ("Debug" instead of "Run"; "Simulate…" instead of "Simulated…";
  "Nearing Usage Limit" instead of "Approaching Quota Usage Limit"). Trust the documentation; the
  session was recorded against an earlier beta.

- **A device that has just updated the OS** → Core AI specialization caches are invalidated by an OS
  update regardless of cache policy, so the first launch after an update pays full specialization
  cost. ✅ **VERIFIED** — Core AI docs.

### 12.3 Build configurations

| Config | Why |
|---|---|
| Xcode 27 + 27.0 deployment target | The happy path. |
| Xcode 27 + a 26.x deployment target | Exercises every `if #available` branch you wrote. This is where a missing `@available` becomes a `dyld` crash. |
| Xcode 26, if you still ship from it | Confirms the 27-only code compiles *out* rather than failing, and reminds you that a 26-built binary still catches `GenerationError`. |
| CI runner without the Metal Toolchain | If you ship `.aimodel` files, prove your CI installs it — otherwise the build fails with a "missing Metal compiler" error that reads like a corrupt checkout. |

---

## 13. Known-bad version claims

Material circulating about this stack contains fabrications. These are the version- and
gating-specific ones. If you see any of them — in a blog post, in an LLM's answer, or in a pull
request — treat the whole source as unreliable.

| Claim | Reality |
|---|---|
| **"iOS 20" / "macOS 17"** | These releases do not exist. The 2026 wave is **26.x**; the 2027 wave is **27.x**. |
| **`.coreaimodel` file extension** | Fabricated. Core AI uses **`.aimodel`** (a *directory*, not a single file) and **`.aimodelc`** for ahead-of-time-compiled artifacts. ✅ **VERIFIED** — Core AI docs and `apple/coreai-models`. |
| **`.aiasset` file extension** | Fabricated. No such thing appears in any Apple document, header or repository in this corpus. |
| **A `coreai-torch convert` CLI** | Fabricated. The conversion entry point is a Python API; the only Core AI command-line tool documented by Apple is **`xcrun coreai-build compile`**. |
| **An on-device LoRA training API in Foundation Models** | Fabricated. One community article describes `FineTuningExample(prompt:completion:)`, "training times under 10 minutes on A17 Pro", a 50 MB adapter cap and pausing below 20% battery. **None of it is attested by any other source.** What actually happened is the opposite: custom adapters were **discontinued** in OS 27, confirmed twice by Apple staff. |
| **"TensorOps is new in iOS/macOS 27"** | Superseded for the base API — the SDK header gates on **26.2**. Only the newer quantized surface (int2/FP4/FP8 operands, ue8m0 scale planes) is 27.0, behind a second macro in the macOS 27.0 beta SDK (checked 2026-07-29). |
| **"The 2M-download PCC limit is annual"** | Wrong. It is **cumulative/lifetime** first-time downloads across any of your apps. |
| **"`developer.apple.com/apple-intelligence/private-cloud-compute/`"** | 404s. Use `developer.apple.com/private-cloud-compute/`. |

One formerly open discrepancy is now settled:

> ✅ **VERIFIED — on-device context size is 4,096 tokens per session.** Apple Technical Note TN3193 states the
> number and its scope directly.[^tn3193-context] A shipping third-party app still contains an
> undated comment claiming an 8,192-token result on iOS 27, but no Apple source corroborates it.
> Continue to read `SystemLanguageModel.default.contextSize` at runtime so model selection and future
> OS changes remain explicit; do not present the third-party comment as a competing platform limit.
> See [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).

---

## 14. Sources

**Apple documentation** (harvested 2026-07-27 via `sosumi.ai` mirrors of
`developer.apple.com/documentation`, `curl -sL`): the `foundationmodels` framework index and the
individual symbol pages for `SystemLanguageModel`, `SystemLanguageModel.Availability`,
`SystemLanguageModel.contextSize`, `SystemLanguageModel.tokenCount(for:)`,
`LanguageModelSession.GenerationError` (deprecated), `LanguageModel`, `LanguageModelCapabilities`;
`adding-server-side-intelligence-with-private-cloud-compute`;
`updating-prompts-for-new-model-versions`;
`supporting-languages-and-locales-with-foundation-models`; the `coreai` framework index and
`compiling-core-ai-models-ahead-of-time`; the `evaluations` framework index; the `speech` framework
index and `updates/speech`. Plus `developer.apple.com/private-cloud-compute/` and
`developer.apple.com/core-ai-debugger/`, both fetched live.

**SDK / headers on disk:** `MetalPerformancePrimitives/MPPTensorOpsAvailability.h`,
`MPPTensorOpsMatMul2d.h`, `MPPTensorOpsTypes.h`.

**Apple sample-code archives** (downloaded and extracted 2026-07-27 from
`developer.apple.com/tutorials/data/documentation/<framework>/<slug>.json`, which exposes the
`docs-assets` ZIP URL that the doc mirrors do not): **Origami — "Crafting a dynamic tutorial for
Apple Intelligence"** (61 Swift files, iOS/macOS/visionOS 27.0 deployment targets), **"Searching
indexed content with natural language"** — the Core Spotlight hiking-trails app (6 Swift files,
iOS 27), and **Book Tracker — "Using Evaluations to evaluate an intelligent feature"** (20 Swift
files, macOS 27). This is compiling first-party Apple code and outranks transcript reconstructions
throughout. Two further archives are quoted **only** as the iOS 26 baseline because they were never
refreshed for 2026: `FoundationModelsCoffeeGame` and `FoundationModelsTripPlanner`, both
`IPHONEOS_DEPLOYMENT_TARGET = 26.0`. `coreai` has **no sample-code projects at all**.

**Repositories read:** `apple/foundation-models-utilities` (`Package.swift`, `README.md`, commit
`376ca60`), `apple/coreai-models` (`Package.swift`, `README.md`), `apple/python-apple-fm-sdk`
(`README.md`, `foundation-models-c/Package.swift`, `FoundationModelsCBindings.swift`),
`ml-explore/mlx-swift-lm` (`Package.swift`, `Libraries/MLXFoundationModels`, commit `3cbf928`,
`.github/workflows/integration_tests.yml`), `ml-explore/mlx` (`device.cpp`,
`kernels/CMakeLists.txt`).

**Apple Developer Forums** (fetched individually, not from the truncated RSS captures): 797271,
805378, 812501, 813757, 823148, 829108, 829539, 830161, 831314, 831404, 831998, 832033, 832910,
833575, 833641, 833642, 833666, 833692, 833716, 833729, 834652, 834749, 835165, 835211, 835897,
835987, 836264, 836760, 836810, 837226, 838444, 838904.

**WWDC26 transcripts:** 241 ("What's new in Foundation Models"), 246 (Core Spotlight), 319 (Private
Cloud Compute), 330 (TensorOps), 334 (`fm` CLI and Python SDK), 339 ("Bring an LLM provider to the
Foundation Models framework"), and the Meet-with-Apple 205 code-along (the iOS 26 baseline).

**Community sources**, used only where labelled: the Noema iOS app's `AFMLLMClient.swift` and
`AppleFoundationModelAvailability.swift` (the 8K `contextSize` observation and the shipping
availability switch), and the community-blog corpus (from which the fabricated on-device-LoRA claim
in [§13](#13-known-bad-version-claims) is drawn as a negative example).

---

### Where to go next

- **Choosing a backend at all:** [1.1 — The 2026 Apple AI stack](01-apple-ai-stack-2026-map.md)
- **The full error and refusal taxonomy:** [Part 2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/README.md)
- **PCC in practice — reasoning levels, quota UX:** [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)
- **Regression-testing across OS updates (the only answer to "no model pinning"):** [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)
- **Specialization, caching and `coreai-build`:** [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md)
- **The 26 → 27 migration, in order:** [Part 17](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-17-migration-from-pre-ios-27/README.md)

[^tn3193-context]: Apple, [TN3193: Managing the on-device foundation model's context
    window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
    (4,096 tokens per `LanguageModelSession`).
