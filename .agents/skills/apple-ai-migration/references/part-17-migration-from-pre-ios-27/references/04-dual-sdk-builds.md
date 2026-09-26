# Building for two SDKs: conditional compilation across 26 and 27

**Part 17 · Migration from pre-iOS 27 · Reference 04**

**Version floor: this guide assumes you must ship a single source tree that compiles under both
Xcode 26 (the iOS/macOS/visionOS **26.x** SDKs) and Xcode 27 (the **27.0** SDKs), and runs on both
26.x and 27.0 devices.** Everything below is written against that constraint. If you only ever build
with Xcode 27 and only ever run on 27, you need `if #available` and nothing else — skip to §10 and
then leave. The interesting version boundaries in this cycle are **26.0**, **26.4** and **27.0**, and
conflating them is the single most common way to accidentally delete a working feature from one of
your two builds.

> ⚠️ **SILENT FAILURE — the whole point of this guide.** Conditional compilation is the one
> migration tool that *deletes code without telling you*. `#if` that evaluates false does not warn.
> A misspelled module name in `canImport` does not warn. An undefined compilation condition does not
> warn. **We measured all three on the shipping 26.5 SDK** (§4.6) — zero diagnostics, in every case.
> So the failure mode of this guide's subject matter is not a red build. It is a green build that
> ships your app to the App Store with the AI feature quietly compiled out, and a crash report
> volume of exactly zero, because nothing crashed. Nothing ran, either.

---

## What this covers

The mechanics of shipping one codebase against two SDKs, organised around the only question that
actually matters at each call site: **is the symbol missing at compile time, or missing at run
time?** Those are different problems with different tools, and using the runtime tool on a
compile-time problem is what broke Apple's own test suite in July 2026.

- **The three tools, and the decision procedure** that tells you which one you need (§1). This is
  the guide's spine; everything after it is detail.
- **`@available` / `if #available`** — the runtime tool, correct when the symbol *exists* in the SDK
  you compile against but may be absent on the device (§2).
- **`#if canImport(Module)`** — the compile-time tool, correct when the whole module may be absent.
  Verified against a real case: **`FoundationModels.framework` does not exist in the watchOS 26.5
  SDK at all** (§3).
- **`#if canImport(Module, _version: N)`** — the compile-time, version-aware tool, and the only
  reliable 27-SDK test in circulation. §4 explains **what the number actually is**, which we
  resolved by measurement rather than by guessing, and marks the parts that remain unknown.
- **Build-setting-driven SDK checks** — `SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=…27.*]`, the
  pattern a shipping third-party app uses for the same job in an Xcode project rather than a
  package (§5).
- **SwiftPM traits** as the package-author's half of the story (§6).
- ⚠️ **The failure that motivates the guide**: `MLXFoundationModels` **compiles to an empty library
  on the 26 SDK**, so `@available` alone is not enough — your call sites must mirror the library's
  `#if` (§7).
- **The worked example**: `ml-explore/mlx-swift-lm` commit `3cbf928`, *"Integration tests: build on
  both macOS 26 and 27 SDKs (#464)"* — 37 test files and one CI workflow, authored by Apple, fixing
  exactly this mistake (§8). It is the best available template for a dual-SDK package.
- **What is hard 27-only** and therefore cannot be papered over with a runtime check (§9), and
  **what genuinely is runtime-gateable** (§10).
- **Over-gating**, the mirror-image mistake: hiding a 26.4 API behind a 27 gate and losing it from
  your 26 build for no reason (§11).
- **Shim construction** — stored properties you cannot annotate, `@unknown default`, and how deep
  the nesting really goes (§12).
- ⚠️ **A load-time failure mode that no runtime guard can catch**: an SDK-interface/dylib symbol
  mismatch that **SIGSEGVs before your `if #available` executes** (§13). This is the reason CI must
  *load* on the target OS, not merely compile.
- **API drift inside a single major version** — enum cases renamed between betas, which no
  conditional-compilation tool can bridge (§14).
- **Known toolchain breakages** with workarounds where any exist, and a plain statement where none
  does: the watchOS 27 beta `CoreImage` module-resolution failure, `SkillActivation` on Xcode 26,
  and the Simulator's host punch-out (§15).
- **CI strategy**: a two-axis matrix, what to run on each cell, and why compile-success is a weak
  signal here (§16).
- **A complete, copyable dual-SDK package and app target** (§17), then a checklist (§18) and the
  declared gaps (§19).

## What this does *not* cover

- **What actually changed between 26 and 27.** The API-level diff is [17.1](01-what-changed-checklist.md).
- **The error taxonomy.** `GenerationError` → `LanguageModelError` and which `catch` fires is
  [17.3](03-error-taxonomy-migration.md). It matters here only as an example of drift you cannot
  `#if` your way out of.
- **The adapter sunset.** [17.2](02-adapter-sunset.md).
- **Artifact-level compatibility** — `.aimodel` bundles, `coreai-torch` wheels, re-export drift.
  That is [17.6](06-toolchain-and-asset-compatibility.md), and it is a *different* dual-version
  problem: your build artifacts have compatibility constraints independent of your source.
- **The shipping consequences** — App Store review, minimum-OS strategy, staged rollout, and what a
  user on 26.x actually sees when your 27 path compiles out. That is
  [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md), and §16 cross-links to it deliberately, because
  a dual-SDK build strategy that nobody has thought through at the distribution layer is a
  half-strategy.

## What you need

- **Both toolchains installed side by side.** `/Applications/Xcode.app` and
  `/Applications/Xcode_27.app` (or `Xcode-beta.app`), selected per-invocation with `DEVELOPER_DIR`,
  not with `xcode-select` — see §16.2. Apple's own CI does it exactly this way.
- **A device on each OS.** Not a Simulator on each OS. §15.3 explains why the Simulator is actively
  misleading for this specific problem.
- Enough patience to accept that **the compiler cannot help you here**. Every tool in this guide is
  a tool for making the compiler stop complaining. That is not the same as making the program work.

---

## How evidence is marked in this guide

Series convention, restated because this guide leans on an unusual mix of sources:

> ✅ **VERIFIED** — read from a header, an SDK on disk, a compiling first-party source file, or an
> Apple documentation page. Citation follows.
>
> 🟡 **RECONSTRUCTED** — the concept is attested; the exact spelling or the exact boundary is
> inferred.
>
> 🔴 **GAP** — not verified. The box says what is unknown, what would resolve it, and what to do
> in the meantime.

Two extra labels appear here:

> 📏 **MEASURED BY US** — run on this machine, this week. Every such claim carries the full
> environment: **macOS 26.5.2 (build 25F84) · Xcode 26.6 (17F113) · `MacOSX26.5.sdk` ·
> 2026-07-28**. These are 26-SDK measurements. **This machine does not have Xcode 27**, so every
> claim about what the 27 SDK reports is marked 🔴 GAP or 🟡 RECONSTRUCTED, never as measurement.
>
> 🧑‍💻 **COMMUNITY** — from a third-party shipping repository, attributed by name. Never presented
> as an Apple statement.

---

## Contents

1. [The three tools, and how to choose](#1-the-three-tools-and-how-to-choose)
2. [`@available` and `if #available`: the runtime tool](#2-available-and-if-available-the-runtime-tool)
3. [`#if canImport(Module)`: the module-absence tool](#3-if-canimportmodule-the-module-absence-tool)
4. [`#if canImport(Module, _version:)`: what the number actually is](#4-if-canimportmodule-_version-what-the-number-actually-is)
5. [SDK checks by build setting: the `[sdk=…27.*]` pattern](#5-sdk-checks-by-build-setting-the-sdk27-pattern)
6. [SwiftPM traits: the package author's half](#6-swiftpm-traits-the-package-authors-half)
7. [⚠️ The empty library](#7-️-the-empty-library)
8. [The worked example: `mlx-swift-lm` commit `3cbf928`](#8-the-worked-example-mlx-swift-lm-commit-3cbf928)
9. [What is hard 27-only](#9-what-is-hard-27-only)
10. [What is genuinely runtime-gateable](#10-what-is-genuinely-runtime-gateable)
11. [Over-gating: the mistake in the other direction](#11-over-gating-the-mistake-in-the-other-direction)
12. [Writing the shim layer](#12-writing-the-shim-layer)
13. [⚠️ The load-time failure no runtime guard can catch](#13-️-the-load-time-failure-no-runtime-guard-can-catch)
14. [Drift inside a single major version](#14-drift-inside-a-single-major-version)
15. [Known toolchain breakages](#15-known-toolchain-breakages)
16. [CI strategy: the matrix, and why compiling is a weak signal](#16-ci-strategy-the-matrix-and-why-compiling-is-a-weak-signal)
17. [A complete dual-SDK package and app target](#17-a-complete-dual-sdk-package-and-app-target)
18. [Checklist](#18-checklist)
19. [Declared gaps](#19-declared-gaps)

---

## 1. The three tools, and how to choose

There are exactly three questions you can ask, and each has exactly one tool that answers it. Almost
every dual-SDK bug in this cycle is somebody answering one question with another question's tool.

| Question | When it is true | Tool | Evaluated |
|---|---|---|---|
| **Does this symbol exist in the SDK I am compiling against?** | The 27 SDK has `PrivateCloudComputeLanguageModel`; the 26 SDK does not. | `#if canImport(Module, _version: N)` — or a build-setting flag (§5) | Compile time |
| **Does this *module* exist in the SDK I am compiling against?** | `CoreAI` exists in the 27 SDK and in no 26 SDK. `FoundationModels` exists in the iOS/macOS/visionOS 26 SDKs and **not** in the watchOS 26 SDK. | `#if canImport(Module)` | Compile time |
| **Does this symbol exist on the device I am running on?** | You compiled with Xcode 27, so `PrivateCloudComputeLanguageModel` resolved fine; the user is on iOS 26.4. | `@available` / `if #available` | Run time |

And the rule that follows from the table, which is worth memorising because it is counter-intuitive
the first time:

> **`@available` cannot save you from a symbol that does not exist in your SDK.** An availability
> annotation is a promise to the *runtime*. If the compiler cannot resolve the name, there is no
> program to run. Conversely, **`#if` cannot save you from a symbol that exists in your SDK but not
> on the user's device** — the `#if` was resolved on your build machine and has no idea what phone
> the binary lands on.

### 1.1 The decision procedure

Work down this list at each call site. Stop at the first line that applies.

1. **Is the module absent from one of my SDKs?** (`CoreAI` on any 26 SDK; `FoundationModels` on the
   watchOS 26 SDK.) → wrap the *import and everything that depends on it* in
   `#if canImport(Module)`.
2. **Is the module present in both SDKs, but the symbol I want was added in 27?**
   (`PrivateCloudComputeLanguageModel`, `ContextOptions`, `LanguageModel`, `DynamicProfile`,
   `Attachment`.) → wrap in `#if canImport(FoundationModels, _version: 2)` *and* `if #available(iOS
   27.0, macOS 27.0, visionOS 27.0, *)`. **Both.** The `#if` gets you compiling on Xcode 26; the
   `#available` gets you not crashing on an iOS 26 device from your Xcode 27 build.
3. **Is the symbol present in both SDKs and I only care whether the device has it?**
   (`SystemLanguageModel.contextSize` — an iOS **26.4** API, present in the 26.4+ SDK.) → `if
   #available` **only**. Do not add an `#if`; see §11 for what that mistake costs you.
4. **Is the difference behavioural rather than symbolic?** (The model refuses prompts on 27 that it
   answered on 26; `catch GenerationError` no longer fires.) → **no conditional-compilation tool
   helps.** Go read [17.3](03-error-taxonomy-migration.md) and write tests.

### 1.2 Why the wrong choice is expensive

Using `@available` where you needed `#if`:

```swift illustrative
// WRONG on the 26 SDK. This does not compile — it does not "compile out".
if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
    let model = PrivateCloudComputeLanguageModel()   // error: cannot find 'PrivateCloudComputeLanguageModel' in scope
    ...
}
```

That is the *good* case: a hard error on your build machine. The expensive case is the one where the
gate you wrote is correct in form but wrong in extent — the symbol compiles out on the 26 SDK, and
so does the entire feature, and nothing anywhere says so. §7 is that case, and §8 is Apple hitting
it in their own repository.

Using `#if` where you needed `@available`:

```swift compile:27 imports:FoundationModels
// WRONG on the 27 SDK. Compiles cleanly. Crashes on an iOS 26.4 device.
#if canImport(FoundationModels, _version: 2)
let model = PrivateCloudComputeLanguageModel()
#endif
```

Built with Xcode 27 with a deployment target of iOS 26.0, this compiles — and the compiler *will*
diagnose the missing `@available` if `PrivateCloudComputeLanguageModel` is annotated
`@available(iOS 27.0, …)`, which it is. So Swift catches this one for you. The category it does not
catch is a 27-only *behaviour* reached through a 26-era symbol; that is [17.1](01-what-changed-checklist.md)
and [17.3](03-error-taxonomy-migration.md) territory.

### 1.3 The shape of a correct gate

For any 27-only Foundation Models symbol, the fully-correct gate has **three** layers, and shipping
code really does write all three:

```swift compile:27
#if canImport(FoundationModels)                      // 1. module exists at all (watchOS 26 fails here)
#if canImport(FoundationModels, _version: 2)         // 2. it is the 27-era module
if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {   // 3. the device is on 27
    // 27-only code
}
#endif
#endif
```

Layer 1 looks redundant on iOS and macOS. It is not redundant on watchOS: ✅ **VERIFIED — 📏 MEASURED
BY US** that `FoundationModels.framework` is absent from `WatchOS26.5.sdk` entirely (§3.2). If your
project has a watch target and you skip layer 1, your watch build fails on Xcode 26 with *"no such
module 'FoundationModels'"*.

Whether you nest the two `#if`s or combine them with `&&` is a style question with one practical
consequence, covered in §4.5.

---

## 2. `@available` and `if #available`: the runtime tool

This is the tool most Swift developers already know, so this section is short and exists mainly to
draw the boundary precisely.

### 2.1 What it does

`@available(iOS 27.0, *)` on a declaration means: *this declaration may only be referenced from
contexts that are themselves iOS-27-or-later*. `if #available(iOS 27.0, *)` creates such a context
at run time. The compiler enforces the pairing statically; the runtime check is a real branch on the
running OS version.

Both halves of the pairing are visible in the quick-start example in `ml-explore/mlx-swift-lm`'s
root `README.md`, which is worth reading closely because it uses **two different floors in one
snippet** (✅ VERIFIED — `README.md:104-141`, read from the local clone at commit `3cbf928`):

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

`@Generable` is **26.0**. `LanguageModelSession(model:)` — the initializer that takes an arbitrary
`LanguageModel` conformer — is **27.0**. That split is the migration in miniature: the *description
of your data* is old API, the *choice of backend* is new API. If you gate the whole file at 27 you
have needlessly deleted your `@Generable` types from the 26 build.

### 2.2 What it cannot do

`if #available` is compiled into the binary as a version comparison. It requires the symbols inside
it to have been resolvable at compile time. Consequences:

- It cannot reference a type the SDK does not declare.
- It cannot be used to *avoid linking* a symbol. The reference is emitted regardless of which branch
  runs — which is precisely the mechanism behind the load-time SIGSEGV in §13. This is the single
  most important sentence in this section.
- It cannot appear as a condition on a stored property. Swift has no
  `@available(iOS 27.0, *) var model: AIModel` on a type that is itself available earlier. §12.1
  gives the standard workaround.

### 2.3 `@unknown default` is now load-bearing

Nearly every enum in this stack is **non-frozen** — Apple can add cases in a point release, and your
`switch` must tolerate it. ✅ VERIFIED against Apple sample code that `LanguageModelError` is
non-frozen with cases `.timeout`, `.guardrailViolation`, `.refusal`, `.contextSizeExceeded`,
`.unsupportedLanguageOrLocale` (see [17.3](03-error-taxonomy-migration.md), which owns this list).

In a dual-SDK build this stops being a style rule and becomes a compile-or-not rule: a `switch` that
is exhaustive on the 26 SDK's case set is *not* exhaustive on the 27 SDK's, and vice versa. Write
`@unknown default` on every `switch` over a framework enum, in both directions.

`mlx-swift-lm` does exactly this at the SamplingMode bridge (✅ VERIFIED —
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`, as it stands after commit `2a76e56`):

```swift prelude:guide-context
switch kind {
case .greedy:
    return .greedy
case .randomTopK(let k, _):
    return .topK(k)
case .randomProbabilityThreshold(let threshold, _):
    return .nucleus(threshold)
@unknown default:
    return nil
}
```

Note what `@unknown default` did **not** save them from: the cases were *renamed*, not added, and a
rename is a compile error no matter how defensive your `switch` is. That is §14.

---

## 3. `#if canImport(Module)`: the module-absence tool

`#if canImport(X)` asks the compiler a single question: *given the current SDK, target triple and
search paths, could I import a module named `X`?* It is answered entirely on the build machine.

### 3.1 The correct use: whole modules that come and go

Use it when the module genuinely may not exist. In this stack that is three situations:

1. **`CoreAI` and its satellites.** Core AI is new in 27; there is no 26 SDK anywhere that has it.
   📏 **MEASURED BY US**: `#if canImport(CoreAI)` evaluates **false** on `MacOSX26.5.sdk`
   (macOS 26.5.2 · Xcode 26.6 · 2026-07-28). And on the 27 side, know what `canImport(CoreAI)`
   is actually testing for: ✅ **SDK-verified** from the captured 27.0 interfaces (2026-07-29),
   `CoreAI` is a one-line **umbrella** — `@_exported public import CoreAIDelegates`
   (`CoreAI-27.0-macos.swiftinterface:5`) — and `CoreAIDelegates`, a **SubFramework** in the SDK,
   `@_export`s `CoreAIAsset` + `CoreAICommon` + `CoreAICompiler` + `CoreAIRuntime`
   (`CoreAIDelegates-27.0:5-8`), all built `-public-module-name CoreAI`. Practical consequences:
   `import CoreAI` is the only import user code needs; the gate `canImport(CoreAI)` stands for the
   whole family; and if a build log or linker error ever names `CoreAIDelegates` or
   `CoreAIRuntime`, that is the same framework, not a missing dependency.
2. **`FoundationModels` on watchOS.** See §3.2.
3. **Cross-platform modules in a package that also builds on Linux** — `CoreImage`, `AVFoundation`,
   `FoundationNetworking`, `Darwin`. This is the classic use and both Apple packages in our corpus
   use it heavily. ✅ VERIFIED in `apple/foundation-models-utilities` at commit `376ca60`:
   `#if canImport(FoundationNetworking)` (`ChatCompletionsLanguageModel.swift:13`),
   `#if canImport(CoreImage)` (`:17`), and `#if canImport(Darwin)` … `#else` selecting **two
   entirely different transport paths** for SSE streaming (`:587` / `:605`). Also ✅ VERIFIED in
   `mlx-swift-lm`: `#if canImport(CoreImage)` around `case ciImage(CIImage)` and
   `#if canImport(AVFoundation)` around `case avAsset(AVAsset)` in
   `Libraries/MLXLMCommon/UserInput.swift:108-173` and `:79-105`.

### 3.2 ✅ VERIFIED: FoundationModels is not in the watchOS 26 SDK

📏 **MEASURED BY US** — macOS 26.5.2 (25F84) · Xcode 26.6 (17F113) · 2026-07-28:

```bash
$ for s in macosx iphoneos watchos appletvos xros; do
    p=$(xcrun --sdk $s --show-sdk-path)
    f=$(find "$p/System/Library/Frameworks/FoundationModels.framework" \
             -name '*.swiftinterface' 2>/dev/null | head -1)
    [ -n "$f" ] && echo "$s: present" || echo "$s: FoundationModels ABSENT"
  done
macosx: present
iphoneos: present
watchos: FoundationModels ABSENT
appletvos: FoundationModels ABSENT
xros: present
```

So on the **26** SDKs, `FoundationModels` ships on macOS, iOS and visionOS, and does not exist on
watchOS or tvOS. This corroborates the framework arriving on watchOS in **watchOS 27** — WWDC26
session 241 states it: *"Private Cloud Compute makes it possible for us to bring the Foundation
Models framework to watchOS. Starting in watchOS 27, you can wear your most powerful intelligence
features right on your wrist."* (✅ VERIFIED — WWDC26 session 241 transcript.)

The practical consequence: a multiplatform target that includes watchOS **must** use bare
`canImport(FoundationModels)` as its outermost gate when built with Xcode 26, or the watch slice
fails to compile. It is the one place in this stack where the bare form is not redundant.

### 3.3 The trap: `canImport(FoundationModels)` is TRUE on the 26 SDK

This is where people go wrong, and it is worth stating as bluntly as possible.

📏 **MEASURED BY US** on `MacOSX26.5.sdk` (macOS 26.5.2 · Xcode 26.6 · 2026-07-28):

```swift illustrative
#if canImport(FoundationModels)
#warning("canImport(FoundationModels) == TRUE")
#else
#warning("canImport(FoundationModels) == FALSE")
#endif
```

```
$ xcrun --sdk macosx swiftc -typecheck probe.swift
probe.swift:2:10: warning: canImport(FoundationModels) == TRUE
```

**TRUE.** Of course it is — Foundation Models shipped in iOS/macOS 26.0. So
`#if canImport(FoundationModels)` tells you *nothing whatsoever* about whether the 27 API surface is
present. A developer who writes the obvious guard:

```swift compile:27 imports:FoundationModels
#if canImport(FoundationModels)          // ← TRUE on the 26 SDK. Useless as a 27 test.
let model = PrivateCloudComputeLanguageModel()
#endif
```

gets a build failure on Xcode 26, is confused, and often concludes that dual-SDK builds are
impossible. They are not; the guard is just the wrong one.

> 🟡 **RECONSTRUCTED — a documentation wrinkle worth knowing about.** `mlx-swift-lm`'s own
> `Package.swift` comment describes the `MLXFoundationModels` target as gated by
> *"`#if canImport(FoundationModels)`"* (✅ VERIFIED — `Package.swift:243-249`, quoted in full in
> §6.1). The actual source uses `#if canImport(FoundationModels, _version: 2)` (✅ VERIFIED —
> `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift:3-4`). The prose is a
> shorthand; the code is the truth. If you are copying the pattern, copy the code.

---

## 4. `#if canImport(Module, _version:)`: what the number actually is

This is the tool the rest of the guide depends on, and it is the one nobody documents. Apple uses it
in a shipping repository, in a commit message, and in a CI comment — and never explains it. So we
measured it.

### 4.1 The form, as Apple writes it

✅ **VERIFIED** — `ml-explore/mlx-swift-lm`,
`Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift:1-10`, read from the local clone
at commit `3cbf928` (HEAD, authored 2026-07-24 by Charlie Le `<charlie_le@apple.com>`):

```swift illustrative
// Copyright © 2026 Apple Inc.

#if FoundationModelsIntegration
#if canImport(FoundationModels, _version: 2)

import Foundation
import Metal
import MLXLMCommon

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension MLXLanguageModel {
    ...
}

#endif  // canImport(FoundationModels)
#endif  // FoundationModelsIntegration
```

and, in the combined form the tests use, ✅ **VERIFIED** —
`Libraries/MLXHuggingFace/FoundationModelsMacros.swift:3`:

```swift illustrative
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```

Apple's own gloss, from the repository's notes on the gate: *"`canImport(FoundationModels,
_version: 2)` is the **SDK version check**: true only on the macOS/iOS/visionOS **27.0 SDK**. On the
26 SDK the whole adapter compiles out to an empty library."*

That tells you what it does. It does not tell you what `2` *is*.

### 4.2 📏 MEASURED: the number is the module's `-user-module-version`

Environment for everything in this subsection: **macOS 26.5.2 (build 25F84) · Xcode 26.6 (17F113) ·
`MacOSX26.5.sdk` · arm64e · 2026-07-28.**

Every Swift framework in the SDK ships a `.swiftinterface` whose header records the flags it was
built with. Read the FoundationModels one:

```bash
$ SDK=$(xcrun --sdk macosx --show-sdk-path)
$ head -3 "$SDK/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/\
FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
// swift-interface-format-version: 1.0
// swift-compiler-version: Apple Swift version 6.3.2 (swiftlang-6.3.2.1.2 clang-2100.0.123.2)
// swift-module-flags: -target arm64e-apple-macos26.5 -target-variant arm64e-apple-ios26.5-macabi
//   -enable-objc-interop -enable-library-evolution -swift-version 6 -enforce-exclusivity=checked -O
//   -library-level api -enable-upcoming-feature InternalImportsByDefault
//   -enable-upcoming-feature MemberImportVisibility -enable-experimental-feature DebugDescriptionMacro
//   -user-module-version 1.5.2 -module-name FoundationModels -package-name com.apple.foundationmodels
```

(Line 3 is one physical line in the file; wrapped here for readability.)

> ✅ **VERIFIED — 📏 MEASURED BY US.** **`FoundationModels` in the macOS 26.5 SDK declares
> `-user-module-version 1.5.2`.** The same value appears in the iOS 26.5 and visionOS 26.5 SDKs.
> `canImport(Module, _version: N)` compares `N` against exactly this number.

Now the behaviour, probed directly:

```swift illustrative
// probe.swift — compiled with: xcrun --sdk macosx swiftc -typecheck probe.swift
#if canImport(FoundationModels, _version: 1)     // → TRUE
#if canImport(FoundationModels, _version: 1.4)   // → TRUE
#if canImport(FoundationModels, _version: 1.5)   // → TRUE
#if canImport(FoundationModels, _version: 1.5.2) // → TRUE
#if canImport(FoundationModels, _version: 1.5.3) // → FALSE
#if canImport(FoundationModels, _version: 1.6)   // → FALSE
#if canImport(FoundationModels, _version: 2)     // → FALSE
#if canImport(FoundationModels, _version: 99)    // → FALSE
```

📏 **MEASURED BY US**, same environment. Every one of those was compiled and the branch taken
recorded via `#warning`. The semantics are unambiguous:

> **`canImport(M, _version: N)` is `userModuleVersion(M) >= N`**, a component-wise version
> comparison, with missing trailing components treated as zero. `_version: 2` means
> "user module version at least **2.0.0**".

### 4.3 What that means for the 26 → 27 boundary

On the 26.5 SDK, FoundationModels is `1.5.2`. On the 27.0 beta SDK — measured 2026-07-29, no longer
merely Apple-asserted — it is `2.0.62.1.402`, so `_version: 2` is true there. Combining the two
measurements:

> 📏 **MEASURED — updated 2026-07-29.** The 27.0 beta SDK has now been read
> (`notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`, Xcode 27.0 beta `27A5228h`):
> the module declares **`-user-module-version 2.0.62.1.402`**. So the major component **did** cross
> from 1 to 2 exactly at the 27 boundary, and `_version: 2` is measured-true on the 27.0 SDK —
> that half of the earlier reconstruction is confirmed.
>
> The other half is retired: the minor does **not** simply track the OS minor. The 27 module moved
> to a five-component scheme (`2.0.62.1.402` — compare `AppIntents`' `300.5.12.1.401` shape), so
> "27.4 would report `2.4.x`" was the wrong extrapolation, and you should not predict any future
> value from the OS version. §19.1 has the full measured table across the captured frameworks.

Do **not** generalise the numbering across frameworks. It is per-module and Apple picks it. 📏
**MEASURED BY US** on `MacOSX26.5.sdk`, same environment:

| Framework | `-user-module-version` on the 26.5 SDK |
|---|---|
| `FoundationModels` | `1.5.2` |
| `SwiftUI` | `7.5.3` |
| `Vision` | `9.5.4` |
| `Translation` | `365.11` |
| `AppIntents` | `300.5.12.1.401` |

`SwiftUI` at 7 tracks the SwiftUI release series (SwiftUI 1 shipped with iOS 13). `Translation` at
365 and `AppIntents` at 300.5.12.1.401 track nothing you can guess — note that `AppIntents` uses
**five** components. The comparison handles arbitrary component counts, but the *meaning* of the
number is a per-framework decision you must look up, not derive.

The recipe for looking it up yourself, which is the durable skill here:

```bash
# What user-module-version does <Framework> declare in the SDK I have?
SDK=$(xcrun --sdk macosx --show-sdk-path)     # or iphoneos / xros / watchos
find "$SDK/System/Library/Frameworks/<Framework>.framework" -name '*.swiftinterface' \
  -exec grep -o 'user-module-version [^ ]*' {} \; | sort -u
```

Run that on both toolchains and you know exactly what number to put in your `#if`. That is a
five-second check that replaces an afternoon of guessing.

### 4.4 🔴 GAP: this spelling is underscored and effectively undocumented

> 🔴 **GAP — two things about `_version:` are still unknown, and you should not pretend otherwise.**
> (A third was closed 2026-07-29.)
>
> 1. ~~**What the 27.0 SDK actually reports.**~~ ✅ **RESOLVED 2026-07-29** — measured
>    **`2.0.62.1.402`** on the Xcode 27.0 beta's macOS 27.0 SDK
>    (`notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`, header line 3), via
>    exactly the `find`/`grep` command this box used to prescribe. §19.1 has the cross-framework
>    table.
> 2. **Whether the spelling is stable.** The leading underscore is Swift's convention for
>    "unofficial, may change". It appears in no Apple documentation page in this corpus and in no
>    WWDC session. Its only Apple-authored appearances anywhere we can see are inside
>    `ml-explore/mlx-swift-lm` source, its commit messages and its CI comments. It has been in the
>    compiler for years and is widely used, so the risk is low — but it is not zero and it is not
>    a promise.
> 3. **Whether the number will keep tracking the way we think it does.** A framework can renumber.
>    If Apple ships FoundationModels `3.x` in a 27 point release, `_version: 2` still evaluates true
>    (it is `>=`) — which is what you want. If Apple *lowered* it, every gate in the ecosystem would
>    silently flip off. Nothing prevents that except Apple's good sense.
>
> **SAFE DEFAULT: use `_version: 2`, exactly as Apple's own package does, and nothing else.** Do not
> invent `_version: 3` for a hypothetical 28, do not invent `_version: 2.1` for a 27 point release,
> and do not build a ladder of version predicates. One boundary, one predicate. If you need a
> second boundary, add a build-setting flag (§5) that you control, rather than a second guess at
> Apple's numbering.

### 4.5 Nested `#if` versus `&&`

Apple's repository uses both forms in the same commit. The library file nests:

```swift illustrative
#if FoundationModelsIntegration
#if canImport(FoundationModels, _version: 2)
```

and the 37 test files combine (✅ VERIFIED — the diff of `3cbf928`, reproduced in §8.2):

```swift illustrative
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```

They are equivalent. The only practical differences:

- **Nesting gives you two `#endif`s to label.** Apple labels them —
  `#endif  // canImport(FoundationModels)` and `#endif  // FoundationModelsIntegration` — and in a
  600-line file that is worth real money. Note that Apple's own label there omits the `_version:`
  part; comments drift, so treat labels as navigation aids, not as specification.
- **Combining is one line to grep for**, which is why the mass-edit across 37 files used it.
  `grep -rn 'canImport(FoundationModels, _version: 2)'` finding every gate in one pass is a genuine
  operational benefit when you are auditing whether your gates are consistent.

Pick one and be consistent, because §7's failure mode is *inconsistency between a library's gate and
its callers' gates*. If they are textually identical, a `grep` audit is trivial.

One formatting note if you use `swift-format`: `mlx-swift-lm` sets
`"indentConditionalCompilationBlocks": false` in its `.swift-format` (✅ VERIFIED — the repo's
`.swift-format` reads `{ "version": 1, "indentation": { "spaces": 4 },
"spacesAroundRangeFormationOperators": true, "indentConditionalCompilationBlocks": false }`). With
deeply nested gates that setting is the difference between readable code and a staircase.

### 4.6 ⚠️ SILENT FAILURE: three ways to write a gate that is quietly always-false

📏 **MEASURED BY US**, macOS 26.5.2 · Xcode 26.6 · `MacOSX26.5.sdk` · 2026-07-28. Each of these was
compiled with `xcrun --sdk macosx swiftc -typecheck` and the taken branch recorded.

**(a) A misspelled module name.** Zero diagnostics.

```swift illustrative
#if canImport(FoundationModelsX)     // typo
// ... your entire 27 feature ...
#endif
```
```
probe3.swift:4:10: warning: typo-module FALSE
```
The only warning emitted is the `#warning` we put in the `#else` branch to observe the result. The
compiler said nothing about `FoundationModelsX` not being a thing. **There is no such diagnostic.**

**(b) An undefined compilation condition.** Zero diagnostics.

```swift illustrative
#if FoundationModelsIntegraton       // trait name misspelled — note the missing 'i'
// ... your entire 27 feature ...
#endif
```
```
probe3.swift:9:10: warning: undefined flag FALSE
```
This is the one that bites package consumers. A SwiftPM trait, a `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
entry and an `-D` flag are all just names. Get the name wrong — or forget to propagate it to a
second target, or to your test target, or to your app extension — and the feature vanishes from that
target only, silently, while the main app works fine. You will find it in TestFlight.

**(c) `_underlyingVersion` instead of `_version` — this one is worse, because it evaluates
TRUE.**

```swift illustrative
#if canImport(FoundationModels, _underlyingVersion: 2)
#warning("underlyingVersion 2 == TRUE")
#else
#warning("underlyingVersion 2 == FALSE")
#endif
```
```
probe.swift:25:15: warning: cannot find user version number for Clang module 'FoundationModels';
                            version number ignored [#ModuleVersionMissing]
probe.swift:26:10: warning: underlyingVersion 2 == TRUE
```

📏 **MEASURED BY US.** `_underlyingVersion` asks about the *Clang* module's version, not the Swift
module's. FoundationModels' Clang module has no user version number, so **the version predicate is
discarded and the condition degrades to a bare `canImport` — which is TRUE on the 26 SDK.** Your
27-only gate is now wide open, and on Xcode 26 the code inside it fails to compile with a pile of
"cannot find X in scope" errors that point at your feature code and never mention the gate.

There *is* a warning — `[#ModuleVersionMissing]` — so this is not perfectly silent. But it is a
warning in a build that already emits warnings, it points at line 25 while the errors point at
lines 40-200, and in a CI log it is invisible. Treat it as silent in practice.

> **Rule: `_version:` for Swift frameworks. `_underlyingVersion:` is for Clang modules that declare
> a version, which Apple's Swift frameworks do not.** If you see `_underlyingVersion` in a gate for
> `FoundationModels` or `CoreAI`, it is a bug.

### 4.7 A gate you can verify locally, in ten seconds

Because all three failures above are silent, **assert the gate** rather than trusting it. Drop this
at the top of the file that carries your gate:

```swift illustrative
// SDKGateAssertions.swift — belongs in the same target as your gated code.
//
// These #warnings are deliberate and permanent. They cost nothing, and they turn
// "which SDK did CI actually use?" from an archaeology exercise into one grep of
// the build log.

#if canImport(FoundationModels, _version: 2)
#warning("BUILD GATE: 27-era FoundationModels — full AI feature set compiled IN")
#elseif canImport(FoundationModels)
#warning("BUILD GATE: 26-era FoundationModels — 27-only features compiled OUT")
#else
#warning("BUILD GATE: no FoundationModels module — all AI features compiled OUT")
#endif

#if canImport(CoreAI)
#warning("BUILD GATE: CoreAI present")
#else
#warning("BUILD GATE: CoreAI absent")
#endif
```

Now `xcodebuild … 2>&1 | grep 'BUILD GATE'` answers, for any build, exactly which world it was
compiled in. In CI, make it an artifact. This is the cheapest possible insurance against §4.6, and
it is the single highest-value thing in this guide relative to its cost.

If a permanent warning offends you, gate the gate:

```swift illustrative
#if VERIFY_SDK_GATES
… the #warnings …
#endif
```

and set `VERIFY_SDK_GATES` only in CI. But note the irony: you have now created another
compilation condition that can be silently misspelled. The permanent version is better.

---

## 5. SDK checks by build setting: the `[sdk=…27.*]` pattern

`canImport(_:_version:)` is a *source-level* test and it only answers questions about modules. Two
situations need something else:

- You are in an **Xcode project** rather than a SwiftPM package, and you want one switch that covers
  many modules and many files, rather than a per-module predicate repeated everywhere.
- You want to gate on **the SDK you are building against**, full stop — including for modules that
  do not usefully bump `user-module-version`, or for your own code that has nothing to do with a
  framework module at all.

The tool is `SWIFT_ACTIVE_COMPILATION_CONDITIONS` with a **build-setting condition on the SDK name**.

### 5.1 The pattern, from a shipping app

🧑‍💻 **COMMUNITY — [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md)** (Noema 3.5, MIT). This is a shipping multi-backend
on-device LLM app that targets iOS 18–27, macOS 26/27 and visionOS 26/27 simultaneously, so it has
had to solve this problem for real. ✅ VERIFIED from the retained research snapshot —
`Noema.xcodeproj/project.pbxproj`, lines ~1391-1395 and ~1456-1460 (the Debug and Release
configurations of the app target):

```
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos27.*]"        = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator27.*]" = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx27.*]"          = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=xros27.*]"            = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=xrsimulator27.*]"     = "$(inherited) NOEMA_ENABLE_XCODE27_APIS";
```

and the header comment that explains the design, ✅ VERIFIED — `Noema/AFMLLMClient.swift:15-18`:

> *"NOTE: Private Cloud Compute, multimodal `Attachment`, and extended reasoning are iOS 27 / Xcode
> 27 SDK symbols that don't exist in the iOS 26 SDK. `#if NOEMA_ENABLE_XCODE27_APIS` gates them at
> compile time; runtime availability checks still apply where the symbols are used."*

That last clause is the important one. The flag replaces `canImport(…, _version: 2)`. It does
**not** replace `if #available`.

### 5.2 Five entries, not one

Note that there are **five** lines, not one. `[sdk=…]` matches the SDK *name*, and device and
simulator have different names. Forget `iphonesimulator27.*` and your feature exists on device and
vanishes in the Simulator — which is exactly the configuration where you would test it first, and
exactly the sort of thing that generates a forum thread titled "Foundation Models doesn't work in
the Simulator" that has nothing to do with Foundation Models. Enumerate every SDK your project
builds for:

| Platform | Device SDK pattern | Simulator SDK pattern |
|---|---|---|
| iOS / iPadOS | `iphoneos27.*` | `iphonesimulator27.*` |
| macOS | `macosx27.*` | — |
| visionOS | `xros27.*` | `xrsimulator27.*` |
| watchOS | `watchos27.*` | `watchsimulator27.*` |
| tvOS | `appletvos27.*` | `appletvsimulator27.*` |
| Mac Catalyst | `macosx27.*` (built against the macOS SDK) | — |

> 🟡 **RECONSTRUCTED.** The five iOS/macOS/visionOS spellings are ✅ VERIFIED from Noema's
> `project.pbxproj`. The watchOS, tvOS and Catalyst rows follow Xcode's standard SDK-name scheme and
> are consistent with it, but no file in this corpus writes them out. Verify by running
> `xcodebuild -showsdks` and reading the `-sdk` column before you rely on them.

`$(inherited)` matters: without it you clobber whatever the project level set, including
`DEBUG`. Every real-world example in this corpus includes it.

### 5.3 The equivalent for a SwiftPM package

Packages do not have `[sdk=…]` conditions. Your options, in order of preference:

1. **`canImport(Module, _version: 2)`** — if a framework module boundary happens to coincide with
   the SDK boundary you care about, which for FoundationModels it does. Prefer this.
2. **A trait** (§6) that consumers opt into.
3. **`unsafeFlags(["-D", "MY_FLAG"])`** — works, but `unsafeFlags` makes the package **unusable as a
   versioned dependency**: SwiftPM refuses to resolve a package that uses `unsafeFlags` when it is
   depended on by tag. This is a hard constraint, not a warning. Do not build a library's SDK
   strategy on it.
4. **`Context.environment[…]` in `Package.swift`** — evaluated at manifest-load time, so it can
   flip `swiftSettings` based on an environment variable you set in CI. `mlx-swift-lm` uses exactly
   this shape for an unrelated purpose (✅ VERIFIED — `Package.swift:315-321`):

   ```swift prelude:guide-context
   if Context.environment["MLX_SWIFT_BUILD_DOC"] == "1"
       || Context.environment["SPI_GENERATE_DOCS"] == "1"
   {
       package.dependencies.append(
           .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
       )
   }
   ```

   It works for build flags too, and it does not poison resolution the way `unsafeFlags` does. The
   cost is that the behaviour now depends on ambient environment, which is its own kind of silent
   failure: a developer building locally without the variable gets a different package than CI does.

### 5.4 When to reach for a build-setting flag rather than `canImport`

Use the flag when **your** code — not a framework — is what differs. Concretely:

- A whole view, view-model or service that only makes sense in the 27 world, spread across many
  files. One flag beats one `canImport` per file, and it reads better.
- A build where you want to *deliberately* compile the 27 path out even though you have the 27 SDK —
  for example, to reproduce a customer's 26 build, or to measure binary size without the feature.
  You can flip a flag; you cannot flip `canImport`.
- Anything in a `.xcconfig`, where a reviewer can see the whole policy in one file.

Use `canImport(_version:)` when the question really is "does this module have the 27 API", which is
most of the time, and when you are writing a **package** that must work for consumers who have never
heard of your flag.

> **A hybrid is legitimate and is what we recommend for an app with a package:** the package gates on
> `canImport(FoundationModels, _version: 2)` (so it works for everyone), and the app defines
> `MYAPP_SDK27` via `[sdk=…27.*]` for its own code. Just make sure the two agree — see §7.3.

---

## 6. SwiftPM traits: the package author's half

Traits are the third mechanism, and they answer a different question again: **not "what SDK is
this?" but "does this consumer want this capability at all?"**

### 6.1 The declaration

✅ VERIFIED — `ml-explore/mlx-swift-lm`, `Package.swift:44-59`, quoted verbatim from the clone at
`3cbf928`, comment included because the comment is the documentation:

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

And the target, showing that a trait can also gate a **dependency edge**, not just source
(✅ VERIFIED — `Package.swift:243-262`):

```swift illustrative
        // Bridges Apple's FoundationModels framework to MLX-powered on-device
        // inference. Public surface is gated by @available(macOS 27 / iOS 27 /
        // visionOS 27, *) and #if canImport(FoundationModels), so the target
        // builds on every Xcode that compiles the rest of mlx-swift-lm. The
        // MLXGuidedGeneration dependency is trait-conditional: it is linked only
        // when FoundationModelsIntegration is enabled, since the adapter
        // references the engine exclusively inside that gate.
        .target(
            name: "MLXFoundationModels",
            dependencies: [
                "MLXLMCommon",
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["FoundationModelsIntegration"])
                ),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Libraries/MLXFoundationModels"
        ),
```

`.when(traits:)` on a dependency is the piece most people miss. It means a consumer who disables the
trait does not merely get dead source — they do not *build* the grammar engine at all, and in this
case that engine is a vendored C++17 xgrammar checkout. The build-time saving is real.

### 6.2 The division of labour: trait × SDK

A trait is a *consumer preference*. `canImport(_version:)` is an *environment fact*. They compose,
and the composition is exactly the `&&`:

```swift illustrative
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```

| Trait | SDK | Result |
|---|---|---|
| on (default) | 27 | Adapter compiled in. The normal case. |
| on (default) | 26 | **Adapter compiles to an empty library.** No error. This is §7. |
| off | 27 | Adapter absent by consumer choice. Also no error. |
| off | 26 | Adapter absent, twice over. |

Note that three of those four cells produce a build with no `MLXLanguageModel` in it and **no
diagnostic distinguishing them**. If your app is missing its MLX-backed session and you do not know
which cell you are in, §4.7's build-gate `#warning`s tell you in one grep.

### 6.3 Why a trait and not just `canImport`

`canImport` alone would be enough to make the package *compile* everywhere. The trait exists for a
different reason, stated in Apple's own comment above: *"Consumers targeting older OS versions can
still use this package for MLXLLM / MLXLMCommon / MLXEmbedders etc. by turning the trait off."*

In other words: the trait is how a consumer says "I am an iOS 17 app, I will never have Foundation
Models, stop dragging its transitive dependencies into my build." That is a supply-chain decision,
not an SDK decision, and `canImport` cannot express it.

If you are **writing** a package in this space, the rule of thumb:

- Gate on **`canImport(…, _version: 2)`** for correctness — so you compile on every toolchain.
- Add a **trait** if disabling the feature meaningfully shrinks the dependency graph or the build.
- Do **not** add a trait purely as an SDK switch. Consumers will forget to set it, and §4.6(b) is
  what happens next.

---

## 7. ⚠️ The empty library

This is the failure that motivates the guide. Everything before it was mechanism; this is
consequence.

> ⚠️ **SILENT FAILURE.** ✅ **VERIFIED:** **`MLXFoundationModels` compiles to an EMPTY LIBRARY on the
> 26 SDK.**
>
> Not "fails to build". Not "emits a warning". **Builds successfully, and contains nothing.**
> Apple states it twice in their own repository, in two different places:
> - `Package.swift:46-52` (the trait comment, §6.1): *"Disabling the trait compiles
>   MLXFoundationModels to an empty library."*
> - the repository's gate documentation: *"On the 26 SDK the whole adapter compiles out to an empty
>   library."*
>
> The trait and the SDK check are separate switches onto the same outcome. Either one being false
> empties the library.

### 7.1 Why `@available` is not enough

Here is the reasoning that traps people, written out so you can see exactly where it breaks.

> *"`MLXLanguageModel` is annotated `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`. So if I
> wrap my call site in `if #available(iOS 27.0, …)`, the compiler is satisfied and the runtime is
> safe. Done."*

True on the 27 SDK. **On the 26 SDK there is no `MLXLanguageModel` at all**, because the entire
declaration lives inside `#if canImport(FoundationModels, _version: 2)` in the library. Your
`if #available` block references a name that does not exist, and you get:

```
error: cannot find 'MLXLanguageModel' in scope
```

with the error pointing at *your* file. Nothing in the message mentions SDKs, `canImport`, traits, or
Foundation Models. From your seat it looks like the package is broken.

The fix is not to relax your availability annotation. The fix is that **your call site must mirror
the library's compile-time gate**:

```swift illustrative
import MLXLMCommon
#if canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels
#endif

func makeSession() -> Any? {
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
```

Stated as a rule, because it generalises past this one package:

> **A compile-time gate is part of a library's public contract, and it is not expressed in its type
> signatures.** If a library gates a symbol behind `#if X`, every consumer of that symbol must gate
> behind the same `#if X`. There is no compiler mechanism that propagates this. There is no
> `@_gatedBy` annotation. The only mechanism is that you read the library's source, or its README,
> or — as happened here — you find out from a red CI run.

✅ VERIFIED, from `mlx-swift-lm`'s own consolidated gotcha list: *"**MLXFoundationModels compiles to
an empty library on the macOS/iOS 26 SDK**; consumers must `#if canImport(FoundationModels,
_version: 2)` their own call sites, not just `@available`."* That sentence is the entire section in
one line, written by the people who maintain the package.

### 7.2 What "empty library" costs you downstream

Three second-order effects that are easy to miss:

**Documentation.** ✅ VERIFIED — `scripts/verify-docs.sh` in `mlx-swift-lm` discovers library
targets via `swift package dump-package` and then explicitly filters one out:

```bash
# MLXFoundationModels is filtered out: it is gated on the FoundationModels v2 SDK, so its DocC
# catalog can't be verified on SDKs that lack it.
… | grep -v '^MLXFoundationModels$'
```

A DocC catalog for an empty module either fails or produces nothing, and `--warnings-as-errors`
turns that into a red build. If you have a docs job, it needs the same exclusion.

**Package indexes.** ✅ VERIFIED — `.spi.yml` lists
`documentation_targets: [MLXLLM, MLXVLM, MLXLMCommon, MLXEmbedders]`. `MLXFoundationModels` and
`MLXGuidedGeneration` are **not** in the Swift Package Index docs. If you are wondering why you
cannot find the adapter's API reference online, that is why — it is not an oversight, it is a
consequence of the gate.

**Linking.** An empty static library still links. You get no undefined symbols, no warning, and a
binary that is missing a feature. Combined with §4.6(b) — a misspelled flag — this is how a feature
disappears from exactly one of your targets.

### 7.3 Auditing your own tree for mismatched gates

Because the contract is textual, audit it textually. Three greps, run in your repo root, that catch
the realistic mistakes:

```bash
# 1. Every gate that mentions FoundationModels. Are they all spelled identically?
grep -rn --include='*.swift' 'canImport(FoundationModels' . | sed 's/.*#if //' | sort | uniq -c

# 2. Files that reference a 27-only symbol WITHOUT any canImport gate in the file.
#    (Crude but effective: adjust the symbol list to the ones you actually use.)
grep -rln --include='*.swift' -E \
  'PrivateCloudComputeLanguageModel|MLXLanguageModel|ContextOptions|DynamicProfile' . \
  | xargs grep -Ln 'canImport(FoundationModels, _version: 2)'

# 3. Availability annotations that mention 27 but sit outside a gate — usually fine on the
#    27 SDK, always a compile error on the 26 SDK.
grep -rn --include='*.swift' '@available(iOS 27' . | head -50
```

Grep #1 is the one that finds real bugs. If its output has more than one distinct line, you have
inconsistent gates somewhere, and the inconsistency is invisible to the compiler on whichever SDK
you happen to build with today.

---

## 8. The worked example: `mlx-swift-lm` commit `3cbf928`

The best available template for a dual-SDK Swift package is a single commit in Apple's own
repository, made because Apple made exactly the mistake §7 describes.

### 8.1 The commit

✅ VERIFIED — read from the local clone of `ml-explore/mlx-swift-lm`, `git show 3cbf928`:

```
commit 3cbf928b5eb24190e8952725699ae6a3bb02824d
Author: Charlie Le <charlie_le@apple.com>
Date:   Fri Jul 24 09:01:37 2026 -0700

    Integration tests: build on both macOS 26 and 27 SDKs (#464)

    The nightly IntegrationTesting job failed to compile on the Xcode 26.5
    runner: the FoundationModels adapter (MLXFoundationModels) is gated behind
    canImport(FoundationModels, _version: 2) (macOS 27 SDK only), but the
    integration test files gated only on the always-set FoundationModelsIntegration
    trait, so they referenced symbols absent on the 26 SDK.

    - Extend the 37 FoundationModels-gated test files' top-level guard to
      '#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)',
      mirroring the library so they compile out on the 26 SDK and stay active on 27.
    - Workflow: prefer Xcode 27 (via DEVELOPER_DIR) when the runner has it so the
      full suite runs; otherwise fall back to the default toolchain and run the
      SDK-agnostic suites (MTP, Qwen3VL/Qwen3.5 vision, Coherence, Gemma4, tool calls).

 .github/workflows/integration_tests.yml            | 23 ++++++++++++++++++++++
 … 37 test files, 2 +- each …
 38 files changed, 60 insertions(+), 37 deletions(-)
```

Read that first paragraph twice. *"the integration test files gated only on the always-set
FoundationModelsIntegration trait"* — they used a **consumer-preference** switch (§6) where they
needed an **environment-fact** switch (§4). It is precisely the category error §1 warns about, made
by the team that wrote the library, in a repository whose `Package.swift` documents the correct gate
in a comment eight lines long.

That is worth sitting with for a moment. If Apple gets this wrong in their own repo, the mechanism
is not obvious, and a code review will not catch it. **Only a build on the other SDK catches it.**

### 8.2 The source change

The diff is 37 identical one-line edits. ✅ VERIFIED — `git show 3cbf928 -- …PlainChatGenerationTests.swift`:

```diff
--- a/IntegrationTesting/IntegrationTestingTests/MLXFoundationModelsIntegration/TextGeneration/PlainChatGenerationTests.swift
+++ b/IntegrationTesting/IntegrationTestingTests/MLXFoundationModelsIntegration/TextGeneration/PlainChatGenerationTests.swift
@@ -1,6 +1,6 @@
 // Copyright © 2026 Apple Inc.

-#if FoundationModelsIntegration
+#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)

 import Testing
 import Foundation
```

Three details worth stealing:

1. **The gate is the first non-comment line of the file**, above the imports. Not around the test
   suite, not around individual methods — the whole file, including its `import FoundationModels`.
   This is the only placement that works, because the imports themselves are what fail on the 26 SDK.
2. **It mirrors the library's gate exactly, token for token.** That is what makes grep #1 in §7.3 a
   meaningful audit.
3. **Files that do not need the gate did not get it.** The tests that survive on the 26 SDK — MTP
   speculative decoding, Qwen3VL/Qwen3.5 vision, coherence, Gemma 4, tool calls — were left alone.
   The commit did not reflexively gate everything, which would have been the easy over-correction and
   would have deleted all coverage from the 26 build (§11 is the general form of that mistake).

One file in the diff is instructive because its gate is in an unusual place. ✅ VERIFIED —
`IntegrationTesting/IntegrationTestingTests/VisionIntegrationTests.swift`:

```diff
 import Testing

 @testable import MLXFoundationModels

-#if FoundationModelsIntegration
+#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```

Here `@testable import MLXFoundationModels` sits **above** the gate. That is legal — importing an
empty module is fine; it is *referencing symbols in it* that fails — and it is a reminder that the
gate has to cover the symbol uses, not necessarily the import of the gated module itself. The
`import FoundationModels` of Apple's framework is the one that must be inside.

### 8.3 The CI change: toolchain selection, not toolchain assumption

✅ VERIFIED — `.github/workflows/integration_tests.yml`, the `Select Xcode` step, verbatim from the
clone:

```yaml
      - name: Select Xcode
        shell: bash
        run: |
          # The FoundationModels integration tests only build against the macOS 27
          # SDK (canImport(FoundationModels, _version: 2)); on the macOS 26 SDK the
          # MLXFoundationModels adapter compiles out and those tests are skipped.
          # Prefer Xcode 27 when the runner has it so the full suite runs; otherwise
          # fall back to the default toolchain and run the SDK-agnostic tests.
          dev=""
          for app in /Applications/Xcode_27*.app /Applications/Xcode-27*.app /Applications/Xcode.app; do
            [ -d "$app" ] || continue
            v=$("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | head -1)
            case "$v" in "Xcode 27"*) dev="$app/Contents/Developer" ;; esac
            [ -n "$dev" ] && break
          done
          if [ -n "$dev" ]; then
            echo "Using Xcode 27 at $dev (full suite, incl. FoundationModels tests)"
            echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"
          else
            echo "Xcode 27 not found; using default $(xcode-select -p)."
            echo "FoundationModels tests will be compiled out (macOS 27 SDK required)."
          fi
```

Four things this gets right, all of which you should copy:

- **It probes rather than assumes.** It does not hardcode `/Applications/Xcode_27.0.app`; it globs
  three patterns and then *asks each one its version* with `xcodebuild -version`. Runner images
  rename Xcode constantly.
- **It uses `DEVELOPER_DIR`, not `xcode-select`.** `xcode-select -s` mutates global machine state and
  requires privileges; `DEVELOPER_DIR` is per-process and scoped to the job. On a self-hosted runner
  — which this is (`runs-on: [self-hosted, macos]`) — the difference between those two is the
  difference between "this job configured itself" and "this job broke every other job on the box".
- **It degrades instead of failing.** No Xcode 27 means a smaller suite, not a red build.
- **It says so out loud.** `"FoundationModels tests will be compiled out (macOS 27 SDK required)"`
  goes into the log. Compare §4.7: the whole art here is making invisible compile-time decisions
  visible in a log you will actually read six weeks later.

### 8.4 What ran where

✅ VERIFIED from the commit message and the test-tree layout:

| | Runs on Xcode 26 | Runs on Xcode 27 |
|---|---|---|
| MTP speculative decoding | ✅ | ✅ |
| Qwen3VL / Qwen3.5 vision | ✅ | ✅ |
| Coherence | ✅ | ✅ |
| Gemma 4 | ✅ | ✅ |
| Tool calls (MLX-native) | ✅ | ✅ |
| Everything under `IntegrationTestingTests/MLXFoundationModelsIntegration/` | ❌ compiled out | ✅ |
| `VisionIntegrationTests.swift` | ❌ compiled out | ✅ |

The 27-only column includes guided generation (14 files), grammar/xgrammar (8), tool calling (4),
reasoning (4), text generation (4), golden-replay (3) and platform-availability (3) suites. That is
the *entire* Foundation Models integration surface. On the 26 SDK, this repository's CI is green
while testing none of it.

> ⚠️ **This is the "compile-success is a weak signal" problem in its purest form.** A green Xcode 26
> run of this repository proves that MLX inference works. It proves **nothing at all** about the
> Foundation Models adapter, because the adapter is not in the binary. If your dashboard shows one
> green check, you have learned half of what you think you have. §16 is about not making that
> mistake.

### 8.5 The rest of the CI, for context

✅ VERIFIED — `.github/workflows/integration_tests.yml` and `pull_request.yml`:

- The integration workflow is `on: workflow_dispatch` **only** — deliberately kept off the PR path
  (header comment: *"Heavy integration tests (Hugging Face model downloads, Metal GPU,
  long-running). Kept out of the PR path so they never block merges"*), `runs-on: [self-hosted,
  macos]`, `timeout-minutes: 120`.
- `-parallel-testing-enabled NO`, because concurrent xctest workers race on the shared on-disk
  Hugging Face cache.
- `-skipPackagePluginValidation` on every `xcodebuild` invocation. Rationale from commit `d242429`:
  *"mlx-swift 0.31.5 added the CudaBuild build-tool plugin, which xcodebuild refuses to run
  non-interactively without this flag."*
- **`swift test` does not work in this repository at all** — `CONTRIBUTING.md:22-55` says to use
  `xcodebuild test … -skipPackagePluginValidation`. If your dual-SDK matrix uses `swift test`,
  check that it works for your package before you build a strategy on it.
- The PR workflow's lint job pins `swift-format` to **`603.0.0`**, built from source, with the
  rationale: *"a new swift-format release can change formatting rules and reformat files no PR
  touched, turning the whole-repo `pre-commit run --all` red on every open PR at once."* Unrelated
  to SDKs, but the same lesson: pin the tools that can silently change your build's meaning.

> 🔴 **GAP.** Commit `5fbb130` describes this workflow as running *"manually (workflow_dispatch) and
> nightly (schedule)"*, but the file as it stands at `3cbf928` has **only** `workflow_dispatch` — no
> `schedule:` trigger. Whether the nightly run was removed, moved elsewhere, or lives in a
> non-public config is unknown. It matters only in that the commit message that motivates this whole
> section says *"The nightly IntegrationTesting job failed to compile"* — so at the time of the
> failure, something was running it on a schedule. **Resolves with:** the repository's current
> `.github/` tree, or the Actions tab.

---

## 9. What is hard 27-only

"Hard 27-only" means: **the symbol does not exist in any 26 SDK**, so no runtime check can reach it
and no amount of `@available` will make your 26 build compile. These need a compile-time gate, full
stop.

### 9.1 The list

| Surface | Gate you need | Evidence |
|---|---|---|
| The **`LanguageModel` / `LanguageModelExecutor` protocol pair** and every conformer-facing type around them | `canImport(FoundationModels, _version: 2)` | ✅ WWDC26 session 241: *"we're opening up our model abstraction layer… built around a new `LanguageModel` protocol that allows both local and server models to back a `LanguageModelSession`."* |
| **`LanguageModelSession(model:)`** — the initializer taking an arbitrary conformer | same | ✅ `mlx-swift-lm` `README.md:104-141`, inside `if #available(iOS 27.0, …)` and inside the package's `_version: 2` gate |
| **`PrivateCloudComputeLanguageModel`** | same | ✅ session 241; ✅ 🧑‍💻 Noema `AFMLLMClient.swift` gates it behind `NOEMA_ENABLE_XCODE27_APIS` |
| **Dynamic Profiles** — `DynamicProfile`, `Profile`, the modifier set, `LanguageModelSession(profile:history:)` | same | ✅ session 241; ✅ Apple sample code (`var body: some DynamicProfile`, `Profile { … }.model(x)`, `.historyTransform(f)`) |
| **`ContextOptions`** (incl. `.reasoningLevel`) | same | ✅ session 339 / 319; ✅ 🧑‍💻 Noema gates `ContextOptions()` behind the 27 flag and falls back to the 26 `streamResponse(to:options:)` overload |
| **`Attachment` / image input on `SystemLanguageModel`** | same | ✅ Apple sample code (`Attachment(image).label(id)` → `@Generable var image: ImageReference`) |
| **`Transcript.Entry.reasoning`** and reasoning segments | same | ✅ 🧑‍💻 Noema reads `case .reasoning(let reasoning)` only inside the 27 gate |
| **The whole Core AI framework** — `AIModel`, `InferenceFunction`, `NDArray`, `AIModelCache`, `SpecializationOptions` | `canImport(CoreAI)` | ✅ 📏 MEASURED BY US: `canImport(CoreAI)` is **FALSE** on `MacOSX26.5.sdk`; there is no `CoreAI.framework` in that SDK's `System/Library/Frameworks` |
| **The Evaluations framework** | `canImport(Evaluations)` | ✅ 📏 MEASURED BY US: **FALSE** on `MacOSX26.5.sdk` |
| **`SpotlightSearchTool`** (it lives in the `_CoreSpotlight_FoundationModels` overlay) | `canImport(_CoreSpotlight_FoundationModels)` | ✅ 📏 MEASURED BY US: **FALSE** on `MacOSX26.5.sdk`; ✅ session 246 names the overlay |
| **`MLXFoundationModels`** (`MLXLanguageModel`, `MLXLanguageModel.Executor`, `MLXDownloadProgress`) | `canImport(FoundationModels, _version: 2)` — mirroring the library | ✅ §7 |
| **`apple/foundation-models-utilities` in its entirety** — `Skills`, `SkillActivations`, `ToggleSkillTool`, `ChatCompletionsLanguageModel`, the history transforms | there is no gate; see §9.3 | ✅ `Package.swift:19-22` declares `platforms: [.macOS("27.0"), .iOS("27.0"), .visionOS("27.0"), .watchOS("27.0")]` |

Environment for all 📏 rows: macOS 26.5.2 (25F84) · Xcode 26.6 (17F113) · `MacOSX26.5.sdk` ·
2026-07-28.

### 9.2 The useful distinction inside that table

Notice that the table uses **two different gates**, and which one you need is decided by a fact you
can check in ten seconds:

- **`FoundationModels` exists in both SDKs** and grew new API. → you need the *version-aware* form,
  `canImport(FoundationModels, _version: 2)`.
- **`CoreAI`, `Evaluations` and `_CoreSpotlight_FoundationModels` do not exist in the 26 SDK at
  all.** → plain `canImport(Module)` is sufficient and correct. No underscored spelling, no version
  number, no §4.4 gap.

This is genuinely good news and it is under-appreciated. Everything that arrived as a *new
framework* in 27 needs only the boring, documented, un-underscored tool. Only Foundation Models —
the one framework that existed before and changed — needs the underscored one. If your 27 feature is
Core AI or Evaluations, §4's gap does not apply to you at all.

### 9.3 The special case: a package with a 27.0 platform floor

`apple/foundation-models-utilities` (commit `376ca60`, tag `1.0.0-beta3`, 2026-07-10) contains
**zero** `#if canImport(FoundationModels…)` guards. ✅ VERIFIED by grep over `Sources/` in the local
clone: no hits. Instead it declares a hard platform floor:

```swift illustrative
  platforms: [
    .macOS("27.0"),
    .iOS("27.0"),
    .visionOS("27.0"),
    .watchOS("27.0")
  ],
```

This is a deliberate, different, and entirely defensible choice: **the package does not attempt to
be dual-SDK.** Its whole reason for existing is 27-era API — `LanguageModel` conformers, Skills,
history transforms — so there is nothing left if you compile it out.

The consequence for you: **you cannot conditionally depend on it.** SwiftPM platform floors are not
conditional. If your app's deployment target is iOS 26 and you add this package, resolution fails.
Your options, in order:

1. **Do not depend on it from a 26-targeting target.** Put the 27-only feature in a separate target
   or a separate app whose floor is 27.0.
2. **Vendor the specific pieces you need** into your own 27-gated files. It is Apache 2.0 licensed
   (✅ VERIFIED — `LICENSE.txt`), zero external dependencies (✅ VERIFIED — `Package.swift:33`,
   `dependencies: []`), and only two commits deep. Copying `SummarizeHistory.swift` into a file
   behind your own `#if canImport(FoundationModels, _version: 2)` is a legitimate move.
3. **Raise your floor to 27.0** and accept that your app does not run on 26. That is a Part 15
   decision, not a Part 17 one — see [15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md).

> 🔴 **GAP.** Whether Apple intends `foundation-models-utilities` to *ever* be dual-SDK is unknown.
> Its `CONTRIBUTING.md` says *"This project is not currently accepting PRs"*, GitHub issues are
> disabled, and it routes bug reports to the Developer Forums. There is no public roadmap.
> **Resolves with:** an Apple statement, or a future commit that adds a gate. **SAFE DEFAULT:**
> treat it as permanently 27-only and architect accordingly.

### 9.4 What "hard 27-only" does *not* include

Two things people wrongly put in this bucket:

- **`@Generable` and the guided-generation macros.** These are **26.0**. Gating them at 27 deletes
  your data model from the 26 build for no reason. ✅ VERIFIED — `mlx-swift-lm` `README.md:104-141`
  annotates `@Generable struct Recommendation` with `@available(iOS 26.0, macOS 26.0, visionOS 26.0,
  *)` and only the *session* with 27.
- **`contextSize` and `tokenCount(for:)`.** These are **26.4**. §11 is about exactly this.

---

## 10. What is genuinely runtime-gateable

The other half of the decision procedure. These are things where the symbol exists in your SDK and
the question is about the *device or the user*, not the toolchain. Use `if #available` and ordinary
runtime probing; do **not** add an `#if`.

### 10.1 Model availability

`SystemLanguageModel.default.availability` and friends answer a question that changes minute to
minute on one device: hardware tier, Apple Intelligence enablement, language settings, region, model
download state. None of that is a compile-time fact.

Two idioms coexist in Apple's own code, and 2026 changed which one Apple prefers:

**Proactive gating** — ask before you act:

```swift illustrative
switch SystemLanguageModel.default.availability {
case .available:
    // show the feature
default:
    // show a non-AI path
}
```

**Reactive catching** — act, and handle the failure:

```swift prelude:guide-context
do {
    let response = try await session.respond(to: prompt)
} catch let error as SystemLanguageModel.Error {
    // availability-shaped failure
} catch let error as LanguageModelError {
    // generation-shaped failure — see 17.3
}
```

✅ VERIFIED from Apple's 2026 sample-code projects: **the 2026 samples dropped proactive
`availability` gating in favour of reactive `SystemLanguageModel.Error` catching.** (The one sample
that still gates proactively is a stale iOS 26 leftover and should not be read as current house
style.) Note also the ordering rule that falls out of that: **`SystemLanguageModel.Error` is checked
*first***, before `LanguageModelError`, and `GeneratedContent.ParsingError` is a third, separate
thing. [17.3](03-error-taxonomy-migration.md) owns the full taxonomy; the point here is only that
this is a runtime concern and belongs nowhere near an `#if`.

> ⚠️ **A 27-beta symptom you will hit and should not design around.** On iOS/macOS 27 betas,
> `SystemLanguageModel.default.availability` has been reported returning
> `.appleIntelligenceNotEnabled` unless the user has enabled "Siri" / "Hey Siri" / "Press Side
> Button for Siri" (Developer Forums threads 835211 and 836760). **An Apple Frameworks Engineer
> confirmed on thread 836760 that this is a bug**, and separately stated that *"The Foundation
> Models framework should be available in Europe even if Siri AI is not enabled. Please file a bug
> report via Feedback Assistant and be sure to include a sysdiagnose."*
>
> Status **unresolved as of 2026-07-28**. Treat it as a known defect with an Apple acknowledgement,
> **not** as a gate to build permanent UX around. Do not ship a "please enable Siri" screen; do make
> sure your reactive error path degrades gracefully, because during the beta window you will see
> this state on machines where it should not appear. Cross-reference
> [17.1](01-what-changed-checklist.md), which owns the availability story.

### 10.2 PCC quota state

Private Cloud Compute has a per-user daily quota, and its state is a pure runtime question. 🧑‍💻
**COMMUNITY — [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md)**, ✅ VERIFIED from the retained research note,
`Noema/AppleFoundationModelAvailability.swift`, showing the full three-layer gate around a purely
runtime probe:

```swift illustrative
    static var status: ApplePrivateCloudComputeAvailabilityStatus {
        guard isRuntimeSupported else {
            return .unavailable(message: String(localized:
                "Apple Private Cloud Compute requires iOS, iPadOS, macOS, or visionOS 27."))
        }
        // … app-level policy gates elided: off-grid mode, network kill switch,
        //    enterprise policy, reachability …

        #if canImport(FoundationModels)
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                let quota = model.quotaUsage
                if quota.isLimitReached {
                    return .limitReached(resetDate: quota.resetDate)
                }
                if case .belowLimit(let information) = quota.status,
                   information.isApproachingLimit {
                    return .approachingLimit
                }
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(message: String(localized:
                    "Private Cloud Compute is not available on this device."))
            case .unavailable(.systemNotReady):
                return .unavailable(message: String(localized:
                    "Private Cloud Compute is not ready yet. Try again in a moment."))
            case .unavailable:
                return .unavailable(message: String(localized:
                    "Private Cloud Compute is currently unavailable."))
            @unknown default:
                return .unavailable(message: String(localized:
                    "Private Cloud Compute is currently unavailable."))
            }
        }
        #endif
        #endif

        return .unavailable(message: String(localized:
            "Private Cloud Compute is unavailable in this build."))
    }
```

Four things to steal from this, all of which generalise:

1. **The bottom `return` is the 26-build behaviour.** Every gate falls through to it. The message
   even says *"unavailable in this build"* — distinct from *"unavailable on this device"*. That
   distinction is what turns a support ticket into a five-second diagnosis.
2. **`@unknown default` on `model.availability`.** Non-frozen enum; mandatory (§2.3).
3. **The runtime probe is inside the compile-time gate, not the other way round.** You cannot invert
   these; the compile-time gate must be outermost or the symbols do not resolve.
4. **`isRuntimeSupported` is a tiny helper** that itself does the gate:

   ```swift illustrative
   static var isRuntimeSupported: Bool {
       #if NOEMA_ENABLE_XCODE27_APIS
       if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
           return true
       }
       #endif
       return false
   }
   ```

   One `Bool` that means "this build, on this device, can do 27 things". Everything else in the
   codebase asks *that*, not the raw gate. This is the single best structural idea in the file —
   see §12.3.

> 📝 **Note on the quota API's granularity, because it changes what UI you can build.** Developer
> Forums thread 835974 ("More Detailed Quota Usage for PCC"): *"You can tell if you've reached your
> quota or are below it. If you are below your quota, you can tell if you're approaching the limit,
> but what does this actually mean? Am I over 50%, 90%, 99%?"* — the API exposes **coarse states
> (reached / below / approaching), not numbers**. Filed as FB23378161. Design your UI for three
> states, not a percentage bar.

### 10.3 Feature presence you can probe

Anything you can ask the framework about at run time belongs here:

- `SystemLanguageModel.default.supportsLocale(_:)` — an **OS 26.0** API. It is present in the base
  `SystemLanguageModel` declaration, not the separate 26.4 context-introspection extension.[^supports-locale-floor]
  An Apple-adjacent forum reply describes it as checking *"against user's
  language settings… Returns `true` if a close language can be supported"* (e.g. a Catalan app
  returns `true` because Spanish is supported).
- `SystemLanguageModel.default.contextSize` — **26.4**. See §11.
- MLX's own availability rollup, which is a nice model for how to expose this in your own package.
  ✅ VERIFIED — `mlx-swift-lm`, `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift`:

  ```swift compile:27
  public enum Availability: Sendable, Equatable {
      case available
      case downloading
      case unavailable(UnavailableReason)

      public enum UnavailableReason: Sendable, Equatable {
          case deviceNotCapable      // no Metal GPU
          case modelNotDownloaded
          case downloadFailed
      }
  }
  ```

  with the doc comment: *"MLX models depend on three things to serve a request: a Metal-capable
  device, the model weights present in the on-disk location supplied at construction, and no
  in-flight download already running. `availability` rolls all three into a single value you can use
  to drive UI affordances ("Tap to download", "Downloading…", "Ready")."* Note that this entire type
  lives **inside** the `_version: 2` gate — a runtime availability API that is itself compile-time
  gated. Both mechanisms, at once, for different reasons.

---

## 11. Over-gating: the mistake in the other direction

Everything so far has been about not under-gating. The opposite mistake is quieter, more common, and
costs you features in the build you are *not* looking at.

### 11.1 The 26.4 trap

Two Foundation Models APIs shipped in **iOS 26.4**, not 27:

- `SystemLanguageModel.contextSize`
- `tokenCount(for:)`

✅ VERIFIED — WWDC26 session 241: *"In iOS 26.4, we released new APIs for inspecting the model's
context size and counting the tokens…"*, and Apple Technical Note **TN3193** ("Managing the
on-device foundation model's context window") confirms `tokenCount(for:)` covers instructions,
prompts, tools, schemas and transcript entries.

They are therefore in the **26.4 SDK**. If your 27-only flag is a big blunt `NOEMA_ENABLE_XCODE27_APIS`-
style switch and you sweep these into it, your Xcode 26 build loses context introspection entirely
— and you will not notice, because the Xcode 27 build works fine and that is the one you develop
against.

🧑‍💻 **COMMUNITY — [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md)** hit this and left a comment about it. ✅ VERIFIED from
the retained research note, `Noema/AFMLLMClient.swift:133-146`:

```swift illustrative
    /// The on-device context is selected by the installed system model. iOS 26
    /// reports 4K while the iOS 27 model reports 8K. `contextSize` is available
    /// in the Xcode 26.4+ SDK, so it must not be hidden behind the Xcode 27 gate.
    static func onDeviceContextLimit() -> Int {
        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let reported = SystemLanguageModel.default.contextSize
            if reported > 0 { return reported }
        }
        #endif
        #endif
        return 4096
    }
```

Read the gates: `canImport(FoundationModels)` (bare — module presence only), an `os()` platform
filter, and `if #available(iOS 26.0, …)`. **No 27 gate.** The comment says why in one sentence:
*"`contextSize` is available in the Xcode 26.4+ SDK, so it must not be hidden behind the Xcode 27
gate."*

That is the correct shape, and it is worth noticing that the availability floor written here (26.0)
is *lower* than the API's actual floor (26.4). That works only because the property resolves at
compile time against a 26.4+ SDK and the author accepts the risk on 26.0–26.3 devices; a stricter
version would use `if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *)`. **Use 26.4.** The looser
form is a latent runtime crash on a 26.2 device.

> ⚠️ **Do not take the "8K on iOS 27" claim in that comment as fact.** ✅ Apple's **TN3193** states
> the on-device context window plainly as **4096 tokens per `LanguageModelSession`**. The 8192
> figure originates in this third-party app's source comment describing what device probing
> returned. It had no device/build/date, never reproduced, and is now **retired historical
> provenance rather than a competing baseline**. The standing advice — which both sources
> agree on — is: **read `contextSize` at run time; hardcode neither number.** The code above does
> exactly that, with 4096 as a fallback only when the property returns `<= 0`.
> [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) owns the context-window story.

### 11.2 The general rule

> **Gate at the narrowest boundary that is actually true.** Every API you sweep into a coarse "27
> stuff" flag is an API you have deleted from your 26 build. The compiler will not tell you. Your
> 27-SDK development machine will not tell you. Your users on 26 will experience a subtly worse app
> and have no vocabulary to report it.

A quick self-audit: for every symbol inside your 27 gate, ask *"what version did this actually ship
in?"* The answer will be 26.0, 26.4 or 27.0. If it is not 27.0, move it out.

### 11.3 The version-floor table for this cycle

Because this is the decision you keep making, here it is in one place. This is a *dual-SDK-oriented*
summary; [17.1](01-what-changed-checklist.md) has the exhaustive version.

| Floor | Representative API | Compile-time gate needed for a 26-SDK build? |
|---|---|---|
| **26.0** | `LanguageModelSession`, `SystemLanguageModel.default`, `@Generable`, `@Guide`, `Tool`, `GenerationOptions`, `Transcript`, `supportsLocale(_:)` | **No.** Present in every 26 SDK. `if #available(iOS 26.0, *)` only — and even that only if your deployment target is below 26.[^supports-locale-floor] |
| **26.4** | `contextSize`, `tokenCount(for:)`; guardrail false-positive reduction (behavioural) | **Only if you build with an SDK older than 26.4.** If your minimum toolchain is Xcode 26.4+, `if #available(iOS 26.4, *)` is the whole story. |
| **27.0** | Everything in §9.1 | **Yes.** `canImport(FoundationModels, _version: 2)` or `canImport(CoreAI)` / `canImport(Evaluations)`, **plus** `if #available(iOS 27.0, *)`. |

Note there is deliberately no **26.2** row in this table. 26.2 matters elsewhere in this series —
MLX's RDMA-over-Thunderbolt support requires macOS 26.2, and the TensorOps availability story has its
own per-point-release ladder — but no Foundation Models API in this corpus lands on 26.2. If you see
a "26.2" claim about Foundation Models, check it.

---

## 12. Writing the shim layer

Gates scattered through a codebase rot. The discipline that keeps a dual-SDK codebase maintainable is
to push every gate to a **boundary layer** and have the rest of your code call ungated Swift.

### 12.1 Stored properties: the `Any` escape hatch

On a pre-27 deployment floor — the case a dual-SDK build exists for — Swift will not let you
write this (with a 27.0 floor the annotation is no longer more restricted than the type, and the
same snippet compiles; the fence's markers record both verdicts):

```swift xfail:sim27-on-26 compile:sim27 imports:FoundationModels
final class Runner {                       // available everywhere
    @available(iOS 27.0, *)                // error: stored properties cannot be
    private var model: PrivateCloudComputeLanguageModel?
                                            // more available-restricted than their type
}
```

There is no availability annotation for stored properties on a less-restricted type. The workaround
in shipping code is to **store `Any?` and cast at the use site**, where a runtime check is legal.

🧑‍💻 **COMMUNITY — `frozen Noema 3.5 snapshot`**, ✅ VERIFIED — `Noema/CoreAILLMClient.swift:74-99`:

```swift compile:27
final class CoreAILLMClient: @unchecked Sendable {
    #if canImport(CoreAI)
    private var loadedModel: Any?               // AIModel (iOS 27+)
    private var loadedFunction: Any?            // InferenceFunction (iOS 27+)
    private var loadedDescriptor: Any?          // InferenceFunctionDescriptor (iOS 27+)
    // Chunked-prefill companion graph (host-cache exports): consumes the prompt
    // in fixed-size token blocks, states handed to the decode graph afterwards.
    private var loadedPrefillModel: Any?        // AIModel (iOS 27+)
    private var loadedPrefillFunction: Any?     // InferenceFunction (iOS 27+)
    private var loadedPrefillDescriptor: Any?   // InferenceFunctionDescriptor (iOS 27+)
    private var activeDecoder: Any?             // CoreAIDecoder (iOS 27+)
    private var activeDecoderBusy = false
    #endif
    #if canImport(CoreAI) && canImport(CoreAILanguageModels)
    private var loadedEngine: Any?              // any InferenceEngine (iOS 27+)
    private var loadedEngineTokenizer: Any?     // any Tokenizers.Tokenizer (iOS 27+)
    private var engineEOSTokenIDs: Set<Int32> = []
    #endif
}
```

Every property carries a comment naming the real type. That convention is doing genuine work: it is
the only type information anyone reading the file will get, because `Any?` erases it and no IDE
feature will bring it back. If you adopt this pattern, adopt the comments with it.

**Cost:** you have opted out of type checking for those properties. A wrong cast is a runtime
`nil` (with `as?`) or a crash (with `as!`). Keep the erased region as small as possible — one class,
ideally one file — and convert back to a concrete type at the first opportunity.

**Alternative when you control the type:** put the stored property on a *separate* type that is
itself `@available(iOS 27.0, *)`, and store *that* as `Any?`. One erasure instead of seven:

```swift compile:27 imports:CoreAI
#if canImport(CoreAI)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private final class CoreAIState {          // whole type is 27-only — properties can be typed
    var model: AIModel
    var function: InferenceFunction
    var descriptor: InferenceFunctionDescriptor
    init(model: AIModel, function: InferenceFunction, descriptor: InferenceFunctionDescriptor) {
        self.model = model
        self.function = function
        self.descriptor = descriptor
    }
}
#endif

final class Runner {
    #if canImport(CoreAI)
    private var state: Any?                 // CoreAIState (iOS 27+)
    #endif

    func use() {
        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
           let state = state as? CoreAIState {
            // fully typed from here down
            _ = state.model
        }
        #endif
    }
}
```

This is the shape to prefer. It confines the erasure to one property and gives you a normal,
type-checked island inside the gate.

### 12.2 The error you throw when the gate is closed

Do not let a closed gate look like a bug. Give it a named error with a message that says *build*, not
*device*. 🧑‍💻 **COMMUNITY — Noema**, ✅ VERIFIED — `Noema/CoreAILLMClient.swift:16-30`:

```swift compile:27 imports:Foundation
enum CoreAILLMClientError: LocalizedError {
    case unsupportedOS
    case frameworkUnavailable
    case generationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return String(localized: "Core AI models require iOS 27 / macOS 27 or later.")
        case .frameworkUnavailable:
            return String(localized:
                "The Core AI framework is unavailable in this build (requires Xcode 27+).")
        case .generationUnavailable(let detail):
            return detail
        }
    }
}
```

`.unsupportedOS` and `.frameworkUnavailable` are **two different cases** with two different messages,
and the difference is exactly `if #available` versus `#if canImport`. That is the whole guide,
expressed as an error enum. The same shape appears in the Foundation Models client
(`AFMLLMClientError.frameworkUnavailable` → *"Foundation Models framework is unavailable in this
build."*).

When a user reports "the AI thing doesn't work", the string *"in this build"* tells you it is a
packaging problem in five seconds. Without it, you spend an afternoon on the device.

### 12.3 One `Bool` to rule them

The best structural idea in the Noema codebase, generalised. Define, in one place, a single
capability flag per feature, computed once, gate-free at the call site:

```swift compile:27
// SDKCapabilities.swift — the ONLY file in the app that contains a 27 gate for Foundation Models.

enum SDKCapabilities {

    /// True iff this binary was built against a 27-era FoundationModels module
    /// *and* is running on a 27-or-later OS.
    static var foundationModels27: Bool {
        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }

    /// True iff the Core AI framework was present at build time and the OS can load it.
    static var coreAI: Bool {
        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }

    /// True iff the Evaluations framework was present at build time.
    /// (Evaluations is a developer-facing framework; you will normally reference this
    /// only from a test target.)
    static var evaluations: Bool {
        #if canImport(Evaluations)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }
}
```

Now the rest of the app writes `if SDKCapabilities.foundationModels27 { … }` — ordinary Swift, no
preprocessor, testable, greppable, and impossible to get subtly inconsistent because there is exactly
one copy of the predicate.

**The catch, and it is a real one:** the *bodies* that use 27 symbols still need their own gates,
because a `Bool` cannot make a name resolve. `SDKCapabilities` cleans up your **policy** decisions —
which UI to show, which backend to offer, what to log — not your **symbol** references. Those still
live in a boundary type. See §17 for how the two fit together.

### 12.4 Two protocols, one app

The scalable pattern when both SDKs must offer the feature in *some* form: declare a protocol in
ungated code, and provide gated conformances.

```swift illustrative
// Ungated: every build has this.
protocol TextGenerator: Sendable {
    var displayName: String { get }
    func generate(_ prompt: String) async throws -> String
}

// Always available (26.0+).
struct SystemModelGenerator: TextGenerator { … }

// 27 only.
#if canImport(FoundationModels, _version: 2)
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct PCCGenerator: TextGenerator { … }
#endif

// The factory is the only place that knows about gates.
enum GeneratorFactory {
    static func all() -> [any TextGenerator] {
        var result: [any TextGenerator] = [SystemModelGenerator()]
        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            result.append(PCCGenerator())
        }
        #endif
        return result
    }
}
```

Your UI iterates `GeneratorFactory.all()`. On a 26-SDK build it gets one generator; on a 27-SDK
build running on 27 it gets two; on a 27-SDK build running on 26.4 it gets one. Three environments,
one code path, zero gates outside the factory.

This is also the shape that makes the failure *visible*: if a tester says "I only see one model in
the picker", you know immediately which of the three environments they are in.

---

## 13. ⚠️ The load-time failure no runtime guard can catch

Everything in §§1–12 assumed that if it compiles and the availability check passes, it runs. There is
one failure mode where that assumption is false, and it is worth its own section because it inverts
the mental model most developers have of `#available`.

> ⚠️ **SILENT FAILURE — and the worst kind, because it is not silent at all; it is a SIGSEGV in a
> place that makes no sense.** ✅ **VERIFIED** — `ml-explore/mlx-swift-lm` commit `1c86cc1`,
> *"fix(MLXFoundationModels): stop respond() crashing when emitting usage on the FM-27 SDK (#439)"*,
> authored 2026-07-17. Commit message, verbatim from the clone:
>
> > The FM-27 beta `.swiftinterface` declares
> > `LanguageModelExecutorGenerationChannel.Response.Action.updateUsage(input:output:metadata: = [:])`,
> > but the shipping FoundationModels dylib exports only the older two-parameter
> > `updateUsage(input:output:)`. Because `emitUsage` relied on the `metadata:`
> > default, the compiler resolved the call to the three-parameter symbol, which
> > does not exist at runtime. dyld cannot bind it, so every `respond()` path
> > crashed (SIGSEGV) the instant generation finished and usage was emitted.
> >
> > Drop the `channel.send(.updateUsage(...))` call, which was the only reference
> > to the missing symbol. **A runtime guard cannot help: the compiled reference
> > alone aborts the process at load under chained-fixups linking, before any
> > check runs.** The `generationObserver` notification is preserved, so usage is
> > still observable. Restore the send, documented inline, once a later SDK ships
> > a dylib that matches its interface.

### 13.1 What actually happened

The `.swiftinterface` — the text file the compiler reads to type-check against a binary framework —
and the **dylib** — the binary the loader actually binds against — **disagreed**. The interface
declared a three-parameter `updateUsage(input:output:metadata:)` with a default for `metadata:`. The
shipping binary exported only the two-parameter form. So:

1. Source calls `updateUsage(input:output:)`, relying on the interface's default for `metadata:`.
2. The compiler resolves that to the **three-parameter** mangled symbol. Compiles clean.
3. At load time, dyld tries to bind that symbol. It is not in the dylib.
4. Under **chained fixups** — the default binding format on arm64 — unresolved imports are processed
   eagerly as the image loads. The process dies. Under the older lazy-binding scheme it would instead
   fault through null the first time the call executed (SIGSEGV at `0x0`).

Either way: **before, or independent of, any `if #available` you wrote.**

The inline comment the fix left in place spells out the reasoning, and is worth reading in full
because you will not find this written down anywhere else. ✅ VERIFIED —
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`, at `emitUsage`:

```swift prelude:guide-context
            generationObserver?(.updateUsage(input: input, output: output, entryID: entryID))

            // TODO: papering over an FM-27 SDK symbol drift -- restore
            // the channel usage send (the commented-out call at the end of this
            // block) once the shipping dylib matches its own interface.
            //
            // Usage is intentionally NOT forwarded to the FoundationModels
            // channel on this SDK. The FM-27 beta `.swiftinterface` declares
            //   Response.Action.updateUsage(input:output:metadata: = [:])
            // (three parameters), but the shipping FoundationModels dylib only
            // exports the older two-parameter
            //   Response.Action.updateUsage(input:output:)
            // Because our call relies on the `metadata:` default, the compiler
            // resolves it to the three-parameter symbol, which does not exist
            // at runtime. dyld cannot bind it: under chained-fixups linking
            // (the arm64 default) the reference aborts the process the moment
            // the image loads, and under lazy binding it faults through null
            // (SIGSEGV at 0x0) the instant this send executes -- crashing every
            // `respond()` path right after generation completes.
            //
            // A runtime `dlsym` guard cannot save this: the compiled reference
            // to the missing symbol is enough to abort at launch regardless of
            // any surrounding check. The only safe option is to not reference
            // the symbol at all, so no `channel.send(.updateUsage(...))` here.
            //
            // Effect: the framework does not receive our per-response usage
            // event, so consumer-visible usage for these responses may be
            // absent or zero. Tests still observe usage through
            // `generationObserver` above. When a later SDK ships a dylib that
            // matches its interface, restore the send:
            //   await channel.send(
            //       .response(
            //           entryID: entryID,
            //           action: .updateUsage(input: input, output: output)))
```

### 13.2 The three lessons

**1. "I checked `#available`" does not save you from a mismatched interface.** Availability is a
*source-level* contract about OS versions. It says nothing about whether the symbol your compiler
picked actually exists in the binary on the machine. When interface and dylib drift — which happens
during a beta cycle — the two are decoupled and only one of them is checkable.

**2. There is no runtime workaround.** Not `if #available`. Not a `respondsToSelector`-style probe.
Not `dlsym`. **The compiled reference is the problem**, not its execution. The only fix is to not
emit the reference: delete the call, or move it behind a `#if` that is false in the affected build.
That is a compile-time decision, which puts this squarely in this guide's territory.

**3. Beware default arguments across a binary boundary.** The specific mechanism that made this
resolvable-but-unbindable is that the *interface* added a parameter *with a default*. Source that
omits the argument silently retargets from the two-parameter symbol to the three-parameter one. From
the call site, nothing changed. Nothing in the diff. Nothing in the build log. This is a general
hazard with library-evolution-enabled frameworks in a beta cycle, not a Foundation Models quirk.

> ⚠️ **The implication for CI, and it is the reason §16 exists.** If your dual-SDK matrix only
> *compiles*, you will not see this class of bug. The MLX fix note says
> *"Verified on-device: `UpdateUsageEmissionTests` passes on all three `respond()` paths
> (unconstrained, guided, tool-calling)."* — **on-device**, because that is the only place the
> question can be asked.
>
> **You must actually LOAD the binary on the target OS.** Not compile it. Not run it in a Simulator
> whose host is a different OS (§15.3). Load it, on the OS you are shipping to. A matrix cell whose
> only assertion is "the build succeeded" would have shipped this crash to every user.

### 13.3 How to detect it early, cheaply

A dylib-vs-interface mismatch shows up as a **launch-time** or **first-call** crash with a dyld
message naming a mangled symbol. Three cheap defences:

```bash
# 1. Smoke test: does the binary even load on the target OS?
#    Cheapest possible assertion, and it catches every chained-fixups binding failure.
xcrun simctl spawn booted /path/to/YourApp.app/YourApp --version   # or any trivial entry point
# On device: run the app's single fastest UI test and assert launch, nothing more.

# 2. What does my binary actually import from the framework?
xcrun nm -m -u /path/to/YourBinary | grep FoundationModels | head -50

# 3. What does the shipping framework actually export?
#    Compare the two lists. Anything in (2) and not in (3) is a load-time bomb.
xcrun nm -gU /System/Library/Frameworks/FoundationModels.framework/FoundationModels \
  | grep -i updateUsage
```

Command 3 must be run **on the target OS**, against the OS's own framework, not against the SDK stub
in Xcode — the whole point is that those two can differ.

> 🔴 **GAP.** Whether a later 27 SDK/dylib pair fixed this specific `updateUsage(input:output:metadata:)`
> mismatch is **unknown as of 2026-07-28**. The fix in `mlx-swift-lm` is a deletion with a TODO, not
> a version-conditional, so the repository itself does not tell you when it is safe to restore.
> **Resolves with:** `nm -gU` on the FoundationModels dylib of a current 27 build, checked against
> the `.swiftinterface` in the matching SDK. **SAFE DEFAULT:** do not call
> `updateUsage(input:output:metadata:)` — and more generally, in a beta cycle, **do not rely on
> default arguments in framework calls**; pass every argument explicitly so the symbol you resolve
> is the symbol you meant.

### 13.4 A related, less lethal cousin: broken `.swiftinterface` in a vendored xcframework

Same family of problem, different severity, and it has a workable fix. 🧑‍💻 **COMMUNITY — Noema**
ships a CI script whose entire job is to defuse a `.swiftinterface` that breaks Xcode Cloud builds.
✅ VERIFIED — `ci_scripts/ci_pre_xcodebuild.sh`:

```sh
# Renames every ExecuTorch.swiftinterface inside the vendored xcframeworks …
mv "$interface_path" "$interface_path.xcodecloud-disabled"
# … and marks the Clang module as a system module so its warnings stop being errors.
sed "s/module ExecuTorch {/module ExecuTorch [system] {/" "$modulemap_path" > "$tmp_path"
```

The technique generalises: **a `.swiftinterface` that will not type-check can be removed** if a
binary `.swiftmodule` for your compiler exists alongside it, and **`[system]` on a module map**
demotes that module's diagnostics. Both are last resorts and both are invisible to anyone reading
your source. If you use them, leave a loud comment and a link to the upstream issue, because the
next person to touch the build will not guess.

---

## 14. Drift inside a single major version

Not every incompatibility is a 26-versus-27 boundary. Some are 27-beta-1 versus 27-beta-3, and no
conditional-compilation tool helps at all — which is worth stating explicitly, because people reach
for `#if` reflexively.

### 14.1 Renamed enum cases

✅ VERIFIED — `mlx-swift-lm` commit `2a76e56`, *"Track the current SDK's SamplingMode.Kind case names
(#431)"*, 2026-07-17:

> FoundationModels renamed `GenerationOptions.SamplingMode.Kind`'s `.top`/`.nucleus` cases to
> `.randomTopK`/`.randomProbabilityThreshold`, which broke compilation against the newer SDK.

```diff
 switch kind {
 case .greedy:
     return .greedy
-case .top(let k, _):
+case .randomTopK(let k, _):
     return .topK(k)
-case .nucleus(let threshold, _):
+case .randomProbabilityThreshold(let threshold, _):
     return .nucleus(threshold)
 @unknown default:
     return nil
 }
```

The commit title says everything: ***track* the current SDK's case names.** They did not write a
shim. There is no `#if` you can write that makes a `switch` compile against two different case
spellings of the same enum without duplicating the whole `switch`, and Apple's own team judged that
not worth it. They picked the newer SDK and moved on.

This is corroborated independently: `apple/foundation-models-utilities` commit `376ca60` ("Updates to
accompany Xcode 27 beta 3") opens its changelog with ✅ *"Renamed SamplingMode enum cases — `.top` →
`.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`."* Two Apple repositories, same rename,
same week.

### 14.2 The strategy that follows

> **For drift *within* the 27 beta series, pick a floor and state it.** Do not attempt to support
> beta 1 and beta 3 simultaneously. Write down which Xcode 27 beta your `main` compiles against, put
> it in your README, and move it forward deliberately.

If you genuinely must support two 27 betas at once — which usually means "an enterprise customer is
pinned" — the only mechanism is a **build-setting flag you control** (§5), because there is no
framework-level predicate fine-grained enough:

```swift illustrative
#if XCODE27_BETA3_OR_LATER
case .randomTopK(let k, _):                   return .topK(k)
case .randomProbabilityThreshold(let t, _):   return .nucleus(t)
#else
case .top(let k, _):                          return .topK(k)
case .nucleus(let t, _):                      return .nucleus(t)
#endif
@unknown default:                             return nil
```

`canImport(FoundationModels, _version: 2)` is true for **both** betas, so it cannot separate them.
📏 The measurement in §4.2 tells you why: `_version` compares against `-user-module-version`, and
while a beta bump *might* move the patch component, you would be inferring a boundary from a number
Apple never documented. §4.4's safe default applies — one predicate, one boundary, and your own flag
for anything finer.

### 14.3 Other drift in the same window, for calibration

`376ca60`'s message doubles as a beta-1 → beta-3 framework changelog. ✅ VERIFIED, quoted in full
because it shows the *shape* of drift you should expect during a beta cycle:

```
  - Renamed SamplingMode enum cases — `.top` → `.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`.
  - Removed `.model(any LanguageModel)` modifier since it's now included in the Foundation Models framework.
  - `SkillActivations` no longer conforms to `RandomAccessCollection` — replaced with a public
    `activeSkillNames` property and an `isActive(_:)` method.
  - Added `urlSessionConfiguration` parameter to `ChatCompletionsLanguageModel.init` — allows tuning
    timeouts, proxies, and other transport settings; defaults to an ephemeral configuration.
  - Added instructions parameter to `Skills` — lets callers override the default leading instructions
    rendered above the skill list.
  - `Skills` now emits a default leading instruction telling the model to silently activate a matching
    skill or otherwise respond normally.
  - `ToggleSkillTool` default description — now instructs the model to activate without asking permission
    or announcing activation.
  - Improved skill instructions formatting — skills are now separated by blank lines rather than inline
    `\n\n` strings; skill headers and descriptions are emitted as separate `Instructions` lines.
  - `ChatCompletionsLanguageModel` schema name uses the new `GenerationSchema.name` API.
  - Fixed `SkillActivations` observation.
```

Count the categories: one rename, one removal (absorbed upstream), one **protocol conformance
dropped**, two additive parameters, and four behavioural changes. Only the additive ones are
compile-safe. The dropped `RandomAccessCollection` conformance is the nastiest: code that did
`ForEach(activations, id: \.self)` simply stops compiling, and the README example that showed it was
stale the day beta 3 shipped.

**The transferable lesson:** during a beta cycle, treat `main` of every dependency in this space —
Apple's included — as tracking the newest beta. Pin by tag, read commit messages, and budget a
rebase every beta drop.

---

## 15. Known toolchain breakages

Three specific, documented, currently-unresolved problems that will cost you a day each if you meet
them cold. For each: what it is, what the evidence is, and what — if anything — you can do.

### 15.1 watchOS 27 beta 2: `Unable to resolve module dependency: 'CoreImage'`

✅ **VERIFIED** — Developer Forums thread **835987** ("FoundationModels Framework on watchOS 27
Beta 2", 2026-06-24). The reported build error, verbatim:

```
/Applications/Xcode-beta.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/\
WatchOS27.0.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/\
FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface:6:15
Unable to resolve module dependency: 'CoreImage'
```

An **Apple Frameworks Engineer** replied, and the answer was accepted:

> *"This is a known bug."*

That is the entire official response. No workaround was given, no radar number, no timeline.

**The mechanism, which nobody stated but which we can now demonstrate.** 📏 MEASURED BY US on
`MacOSX26.5.sdk` (macOS 26.5.2 · Xcode 26.6 · 2026-07-28), the *macOS* FoundationModels interface
begins:

```
// swift-interface-format-version: 1.0
// swift-compiler-version: Apple Swift version 6.3.2 …
// swift-module-flags: … -user-module-version 1.5.2 -module-name FoundationModels …
public import CoreGraphics
public import Foundation
public import Observation
…
```

— `CoreGraphics`, not `CoreImage`, on the 26 SDK. The forum error points at **line 6, column 15** of
the *watchOS 27* interface, which is exactly where a `public import CoreImage` would sit in that
header block. And 📏 MEASURED BY US: **`WatchOS26.5.sdk` contains 128 frameworks and none of them is
`CoreImage`** — while `MacOSX26.5.sdk` has it. So the picture is coherent: 27's image-attachment API
pulled a `public import CoreImage` into the FoundationModels interface, and watchOS has no CoreImage
to resolve it against. The framework's own interface is unbuildable on the platform it was shipped
for.

> 🔴 **GAP — status as of 2026-07-28 is unknown.** The report is against **watchOS 27 beta 2**;
> whether beta 3 or later fixed it is not established by any source in this corpus, and the forum
> thread has one reply and no follow-up.
>
> **Resolves with:** an Xcode 27 install with a current watchOS 27 SDK, and one command:
> `grep -n 'public import' "$(xcrun --sdk watchos --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-watchos.swiftinterface" | head`.
> If `CoreImage` no longer appears, it is fixed.
>
> **Workaround: there is none.** You cannot patch an Apple SDK interface in a way that survives a
> clean build or a CI runner, and §13.4's rename-the-interface trick does not apply — that works
> only for a *vendored* xcframework you control, and only when a matching binary `.swiftmodule`
> exists. There is no supported way to make a broken system-framework interface resolve.
>
> **SAFE DEFAULT:** if you have a watchOS target, **gate it out of the Foundation Models path
> entirely** on the affected toolchain and ship the watch experience without on-device AI:
>
> ```swift
> #if os(watchOS)
> // FoundationModels on watchOS 27 beta 2 has an unbuildable .swiftinterface
> // (forums 835987, Apple: "This is a known bug"). Re-test each beta; remove
> // this gate the moment `public import CoreImage` leaves the interface.
> // Until then the watch app talks to the phone, or does without.
> #else
> import FoundationModels
> #endif
> ```
>
> Re-test on every beta. This is a bug that will go away; the cost of checking is one `grep`.

Note the second-order consequence, which is easy to miss: **watchOS Foundation Models is a
PCC-primarily surface**. WWDC26 session 241 introduces watchOS support in the context of Private
Cloud Compute (*"Private Cloud Compute makes it possible for us to bring the Foundation Models
framework to watchOS"*), and the on-device model is not described as running on the watch. Separately,
🧑‍💻 a developer self-answered forums thread **834652**: *"not only does the Watch have to be running
WatchOS 27, it also needs to be paired to an iPhone with Apple Intelligence enabled. This is despite
the fact that PCC queries from WatchOS 27 go straight to the server."* — **[UNVERIFIED by Apple]**,
but if true it means an Apple Watch Series 11 paired to an iPhone 15 gets nothing. Your watch
feature has a device-pairing gate on top of everything in this guide.

### 15.2 `SkillActivation` / `foundation-models-utilities` will not build on Xcode 26

✅ **VERIFIED** — Developer Forums thread **835165**, *"SkillActivation Framework Fails to Build in
Xcode 26 When Using foundation-models-utilities"* (2026-06-18, 2 replies). An **Apple Frameworks
Engineer** asked:

> *"Can you share some of the specific compilation errors you're seeing?"*

The thread was **never resolved**. No fix, no workaround, no follow-up.

**But the cause is not mysterious, and you can confirm it in ten seconds.** ✅ VERIFIED from the
clone at commit `376ca60`: `apple/foundation-models-utilities` declares
`platforms: [.macOS("27.0"), .iOS("27.0"), .visionOS("27.0"), .watchOS("27.0")]` and contains
**zero** `#if canImport(FoundationModels…)` guards (grep over `Sources/`: no hits). Its `Skills`
directory — `Skill.swift`, `SkillActivations.swift`, `SkillBuilder.swift`, `Skills.swift` — is
ordinary 27-era Swift with no gate at all.

So: **this package is not dual-SDK and was never meant to be.** On Xcode 26 you do not have the 27
FoundationModels module, so every type it references is missing, and you get a wall of "cannot find
X in scope" errors that look like a package bug and are actually a floor violation.

> **Workaround, in order of preference:**
> 1. **Build it with Xcode 27.** This is not a bug to work around; it is the package's stated floor.
> 2. **Do not depend on it from a 26-targeting target.** §9.3.
> 3. **Vendor the four `Skills/` files** into your own tree behind
>    `#if canImport(FoundationModels, _version: 2)`. Apache 2.0, zero dependencies, ~4 small files.
>    You take on maintenance; in exchange your package compiles on both toolchains.
>
> **What does not work:** adding `.when(platforms:)` to the dependency, or lowering the floor in a
> fork. The floor is not the problem; the missing symbols are.

⚠️ **And one live hazard if you do vendor it:** its `SkillActivations` **dropped its
`RandomAccessCollection` conformance in beta 3** (§14.3). Its own README still shows
`ForEach(assistant.activations, id: \.self)`, which no longer compiles. Use `activeSkillNames` and
`isActive(_:)`. ✅ VERIFIED — commit `376ca60`'s message; the README snippet at `:150`/`:158` is
stale.

### 15.3 The Simulator punches out to the host macOS

This one is not a build failure. It is worse: it is a *plausible-looking runtime failure* that has
nothing to do with your code, and it is described in this corpus as the single biggest source of
phantom bug reports in the 2026 forums.

✅ **VERIFIED** — Developer Forums thread **831404**, accepted answer from an **Apple Designer
(Apple)**:

> *"So currently we are not able to replicate this issue on macOS 27.0 and Xcode 27.0, but given
> similar historical issues we had at launch last year, I highly suspect the underlying cause is
> that you're running macOS 26.
>
> **Why?** Xcode 27.0 contains the latest SDK, but the on-device `SystemLanguageModel` is actually
> built into the OS. **Meaning** that when you run simulator from Xcode, the simulator is actually
> **"punching out" to macOS** to run the model, using the 26.5 model inference code in the OS.
> Whenever we see "weird" errors like this, it's usually an underlying incompatibility between the
> Xcode SDK and OS for running the model. :(
>
> **Suggested Fix** Update a physical device to 27.0."*

**Read that in the context of this guide.** A Simulator run gives you: the **27 SDK** at compile
time, and the **host Mac's OS** at inference time. That is a fourth environment, not one of the
three you meant to test. If your host is macOS 26, a Simulator running "iOS 27" is executing 26 model
code. Every conclusion you draw about 27 behaviour from that run is worthless.

Two corroborating facts, both ✅ VERIFIED:

- **PCC does not work in the Simulator at all.** Thread 831998, Frameworks Engineer, accepted:
  *"There is a known issue that Private Cloud Compute does not currently work in simulators."*
  Documented in the iOS 27 release notes as known issue **177684296**, with the stated workaround:
  *"Use a physical device running OS 27.0."*
- The failing error is a bare `LanguageModelError` **Code=-1** wrapping
  `ModelManagerServices.ModelManagerError Code=1046` — an undocumented code Apple never explained.
  A second developer reported the same `-1` on a **physical iPhone 17 Pro Max**, so `-1` is not
  Simulator-exclusive; it is just far more likely there.

> **Consequences for your matrix, and these are non-negotiable:**
>
> 1. **A Simulator cell can prove "it compiles" and "it launches". It cannot prove "it works".**
> 2. **`macOS 27 host + iOS 26 Simulator` is not a valid way to test your 26 path**, and neither is
>    the reverse. Compile-time SDK and inference-time OS are independent axes in the Simulator, and
>    only devices collapse them.
> 3. **Every behavioural assertion belongs on a device**, at the OS you are asserting about.
>
> The good news: the *load-time* assertion from §13.3 — does this binary bind its symbols? — is
> still meaningful in a Simulator whose host OS matches the SDK, because dyld binding happens
> against the Simulator runtime. It is the *model* that punches out, not the linker.

---

## 16. CI strategy: the matrix, and why compiling is a weak signal

### 16.1 The two axes

The mistake is to think of this as one axis ("26 or 27"). It is two, and they are independent:

- **Build axis — which SDK compiled the binary.** Decides which `#if` branches exist. Controlled by
  `DEVELOPER_DIR`.
- **Run axis — which OS the binary executes on.** Decides which `if #available` branches run, which
  model code answers, and whether dyld can bind your symbols. Controlled by which device you plug in.

That gives four cells, three of which you must cover:

| | Run on 26.x device | Run on 27.0 device |
|---|---|---|
| **Built with Xcode 26** | ✅ **Cell A** — your existing users, today. Non-negotiable. | ✅ **Cell B** — your existing binary meeting the new OS. **This is the cell people forget, and it is where behavioural regressions surface** ([17.3](03-error-taxonomy-migration.md)). |
| **Built with Xcode 27** | ✅ **Cell C** — your next release meeting old users. Where `if #available` fallbacks get exercised. | ✅ **Cell D** — the happy path. The only cell most teams test. |
| **Simulator, any** | ⚠️ compile + launch only | ⚠️ compile + launch only — §15.3 |

Cell B is the one that matters most for [Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) reasons: it
is what happens to your **already-shipped** app when a user updates their phone. You do not get to
choose whether that cell runs; you only get to choose whether you found out first. It is also the
cell no amount of conditional compilation can help with — the binary is fixed, and only the OS
changed underneath it.

### 16.2 Toolchain selection

Copy Apple's `Select Xcode` step (§8.3) more or less verbatim. The three rules:

1. **Probe, do not hardcode.** Glob candidate paths, then ask each `xcodebuild -version`.
2. **`DEVELOPER_DIR`, never `xcode-select -s`.** Per-process, no privileges, no cross-job damage.
   On a shared or self-hosted runner this is the difference between a scoped job and a global
   mutation.
3. **Degrade loudly.** A missing toolchain should shrink the suite and say so in the log, not turn
   the build red — otherwise the first runner-image update takes your whole pipeline down.

A minimal two-cell matrix, adapted from Apple's workflow to run *both* SDKs rather than preferring
one:

```yaml
name: Dual-SDK build

on: [push, pull_request]

jobs:
  build:
    runs-on: [self-hosted, macos]
    strategy:
      fail-fast: false          # one SDK failing must not hide the other's result
      matrix:
        sdk: [26, 27]
    steps:
      - uses: actions/checkout@v6
        with: { submodules: recursive }

      - name: Select Xcode ${{ matrix.sdk }}
        shell: bash
        run: |
          dev=""
          for app in /Applications/Xcode_${{ matrix.sdk }}*.app \
                     /Applications/Xcode-${{ matrix.sdk }}*.app \
                     /Applications/Xcode.app; do
            [ -d "$app" ] || continue
            v=$("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | head -1)
            case "$v" in "Xcode ${{ matrix.sdk }}"*) dev="$app/Contents/Developer" ;; esac
            [ -n "$dev" ] && break
          done
          if [ -z "$dev" ]; then
            echo "::warning::Xcode ${{ matrix.sdk }} not installed on this runner; skipping."
            echo "SKIP=1" >> "$GITHUB_ENV"
            exit 0
          fi
          echo "DEVELOPER_DIR=$dev" >> "$GITHUB_ENV"

      - name: Build
        if: env.SKIP != '1'
        run: |
          xcodebuild -version
          swift --version
          xcodebuild build-for-testing \
            -scheme YourScheme \
            -destination 'platform=macOS' \
            -skipPackagePluginValidation \
            | tee build-${{ matrix.sdk }}.log

      - name: Record which gates were compiled in     # ← §4.7
        if: env.SKIP != '1'
        run: |
          echo "=== BUILD GATES (SDK ${{ matrix.sdk }}) ==="
          grep 'BUILD GATE' build-${{ matrix.sdk }}.log | sort -u | tee gates-${{ matrix.sdk }}.txt

      - uses: actions/upload-artifact@v4
        if: env.SKIP != '1'
        with:
          name: gates-${{ matrix.sdk }}
          path: gates-${{ matrix.sdk }}.txt
```

The `Record which gates were compiled in` step is the one that turns this from a build matrix into
an *informative* build matrix. Two artifacts, four lines each, and a reviewer can see at a glance
that the 26 build compiled the AI feature out and the 27 build compiled it in. If those ever come
back identical, something is wrong and you find out in seconds instead of in TestFlight.

`fail-fast: false` is not optional here. The default cancels sibling jobs on first failure, and the
whole point of the matrix is to learn about both cells.

### 16.3 What to run in each cell

| Cell | Assert | Do **not** assert |
|---|---|---|
| **Build 26** | Compiles. Gate log says 27 features are OUT. Non-AI unit tests pass. The AI *fallback* path is exercised (your non-AI experience is not broken). | Anything about Foundation Models 27 API — it is not in the binary. |
| **Build 27** | Compiles. Gate log says 27 features are IN. Full unit-test suite. | — |
| **Run on 26.x device** | App launches (dyld binding — §13). AI feature degrades to its 26 behaviour. Error handling catches the **26** taxonomy. | 27-only behaviour. |
| **Run on 27.0 device** | App launches. Full feature set. Error handling catches the **27** taxonomy. Golden-output / evaluation suite. | — |

Note the asymmetry in the "Build 26" row: the useful assertions there are almost all **negative** —
"the AI code is absent, and the app is still coherent without it". That is unusual to write and easy
to forget, and it is exactly the coverage that catches an over-gating mistake (§11).

### 16.4 Why compile-success is a weak signal

Three independent reasons, each demonstrated earlier in this guide:

1. **A false `#if` compiles perfectly** (§4.6). A misspelled module or flag produces a *green* build
   with the feature deleted. Compilation cannot distinguish "gated out correctly" from "gated out by
   accident".
2. **An empty library links fine** (§7.2). No undefined symbols, no warnings, no feature.
3. **A binary that compiles can fail to load** (§13). Interface/dylib drift is invisible until dyld
   tries to bind, which happens on the device, at launch — after every compile-time check has
   already passed.

Which yields the rule:

> **Every matrix cell must assert something stronger than "the build succeeded."** The cheapest
> strengthening, in order: (a) grep the gate log (§4.7); (b) launch the binary on the target OS
> (§13.3); (c) run one end-to-end generation and assert on the output.

`mlx-swift-lm` is a good illustration of exactly how weak the compile signal is in this domain: on
Xcode 26 its CI is **green while testing none of the Foundation Models surface**, because 37 test
files compiled out (§8.4). That is correct engineering — there is nothing to test — but a dashboard
showing one green check would be lying to you about coverage.

### 16.5 Integration tests belong off the PR path

Apple's judgement, ✅ VERIFIED from `.github/workflows/integration_tests.yml`'s header comment:

> *"Heavy integration tests (Hugging Face model downloads, Metal GPU, long-running). Kept out of the
> PR path so they never block merges."*

`on: workflow_dispatch`, `runs-on: [self-hosted, macos]`, `timeout-minutes: 120`,
`-parallel-testing-enabled NO` (concurrent workers race on the shared on-disk model cache),
`-resultBundlePath …xcresult` so failures are inspectable.

For a dual-SDK matrix specifically: keep the **fast** cells (compile both SDKs, grep the gates) on
every PR, and the **slow** cells (device runs, model downloads, evaluation suites) on a schedule or
a manual trigger. The compile matrix is seconds-to-minutes and catches every gate mismatch; the
device matrix is tens of minutes and catches everything else.

### 16.6 The Evaluations framework is the right tool for the run axis

The run axis asks behavioural questions — *does the model still answer this prompt the way it used
to?* — and those need a behavioural harness, not `XCTAssert`. That is what Evaluations is for, and
Apple positions it explicitly as the defence against silent behaviour change across OS updates,
because **there is no model version pinning API**.

📏 MEASURED BY US: `canImport(Evaluations)` is **FALSE** on `MacOSX26.5.sdk`, so an evaluation suite
is inherently a 27-toolchain artifact — but it can run against a **26 device** from an Xcode 27 host,
which is exactly Cell C, and that is the most valuable evaluation you can run during a migration.
[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) owns the framework; [17.3](03-error-taxonomy-migration.md) has
the regression-test recipe for the specific case of refusal/guardrail drift.

### 16.7 Cross-link: the shipping consequences

A dual-SDK build strategy is only half a plan. The other half is distribution, and it lives in
[Part 15](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md):

- **There is no Required Device Capability for Apple Intelligence** (✅ VERIFIED — forums thread
  836810). You cannot filter your app on the App Store by AI capability, and Apple expects a baseline
  non-AI experience. Your 26 build's compiled-out state is therefore not a hypothetical; it is the
  experience of a large fraction of your users, and it must be good.
- **Minimum-OS and staged-rollout decisions** interact directly with which cells of §16.1 you can
  stop caring about. Raising your floor to 27.0 deletes Cells A, B and C — and a large chunk of your
  installed base with them.
- **Model and asset distribution** has its own version story that is *independent of your source
  gates*. See [15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
  and [17.6](06-toolchain-and-asset-compatibility.md).

---

## 17. A complete dual-SDK package and app target

Everything above, assembled. This compiles on Xcode 26 and Xcode 27, runs on 26.x and 27.0, and has
exactly one file containing a gate.

### 17.1 `Package.swift`

```swift prelude:external-module
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "dual-sdk-example",
    platforms: [
        // The FLOOR is 26.0 — not 27.0. Everything 27-only is behind a gate,
        // so this package remains usable by a 26-targeting app.
        .macOS("26.0"),
        .iOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(name: "TextGen", targets: ["TextGen"]),
    ],
    traits: [
        // Optional. Include a trait ONLY if disabling the feature meaningfully
        // shrinks the dependency graph (see §6.3). If it does not, leave this out —
        // an unset trait is a silent always-false gate (§4.6b).
        .trait(
            name: "Advanced27Features",
            description: "Enables the 27-only Private Cloud Compute backend."
        ),
        .default(enabledTraits: ["Advanced27Features"]),
    ],
    targets: [
        .target(name: "TextGen", path: "Sources/TextGen"),
        .testTarget(name: "TextGenTests", dependencies: ["TextGen"], path: "Tests/TextGenTests"),
    ],
    swiftLanguageModes: [.v6]
)
```

Two decisions worth naming:

- **The platform floor is 26.0, not 27.0.** That is what makes the package dual-SDK at all. Compare
  `apple/foundation-models-utilities`, which chose 27.0 and is therefore not dual-SDK by
  construction (§9.3). Both choices are valid; they are different products.
- **Test target has the same floor.** If your tests reference gated symbols, they need the same gate
  as the library — that is the entire content of commit `3cbf928` (§8).

### 17.2 `Sources/TextGen/Capabilities.swift` — the gate log

```swift compile:27
// Capabilities.swift
//
// The build-gate assertions from §4.7. These #warnings are permanent and deliberate.
// `xcodebuild … | grep 'BUILD GATE'` answers "which world did this compile in?"

#if canImport(FoundationModels, _version: 2)
#warning("BUILD GATE: 27-era FoundationModels — PCC backend compiled IN")
#elseif canImport(FoundationModels)
#warning("BUILD GATE: 26-era FoundationModels — PCC backend compiled OUT")
#else
#warning("BUILD GATE: no FoundationModels module — all backends compiled OUT")
#endif

/// Single source of truth for "can this build, on this device, do 27 things?".
/// Ordinary Swift: testable, greppable, no preprocessor at the call site.
public enum Capabilities: Sendable {

    /// Built against a 27-era FoundationModels module AND running on 27+.
    public static var foundationModels27: Bool {
        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }

    /// Built against a FoundationModels module of any vintage AND running on 26+.
    public static var foundationModels26: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) { return true }
        #endif
        return false
    }

    /// The 26.4 context-introspection APIs. NOT gated at 27 — see §11.
    public static var contextIntrospection: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) { return true }
        #endif
        return false
    }

    /// Human-readable summary, for your diagnostics screen and your bug reports.
    public static var summary: String {
        """
        FoundationModels 26: \(foundationModels26)
        FoundationModels 27: \(foundationModels27)
        Context introspection (26.4): \(contextIntrospection)
        """
    }
}
```

`Capabilities.summary` in your app's about/diagnostics screen pays for itself the first time a tester
files "AI doesn't work" with a screenshot.

### 17.3 `Sources/TextGen/TextGenerator.swift` — the ungated protocol

```swift illustrative
import Foundation

/// The app's entire view of text generation. No preprocessor directives below this line.
public protocol TextGenerator: Sendable {
    var displayName: String { get }
    var requiresNetwork: Bool { get }
    func generate(_ prompt: String) async throws -> String
}

public enum TextGenError: LocalizedError {
    /// The OS is too old. The symbol exists in this binary; the device cannot run it.
    case unsupportedOS(String)
    /// The symbol is not in this binary at all. A packaging/toolchain problem, not a device one.
    case unavailableInThisBuild(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOS(let what):
            return "\(what) requires iOS 27, macOS 27, or visionOS 27 or later."
        case .unavailableInThisBuild(let what):
            return "\(what) is unavailable in this build (requires the Xcode 27 SDK)."
        }
    }
}
```

Two error cases, because §12.2: *"requires iOS 27"* and *"unavailable in this build"* are different
diagnoses and only one of them is the user's problem.

### 17.4 `Sources/TextGen/SystemBackend.swift` — the 26 backend, ungated

```swift illustrative
#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

/// Uses the built-in on-device model. Available from 26.0.
public struct SystemBackend: TextGenerator {
    public let displayName = "On-device model"
    public let requiresNetwork = false

    public init() {}

    public func generate(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw TextGenError.unsupportedOS(displayName)
        }
        let session = LanguageModelSession()
        return try await session.respond(to: prompt).content
        #else
        throw TextGenError.unavailableInThisBuild(displayName)
        #endif
    }

    /// 26.4 API — deliberately NOT behind a 27 gate (§11).
    public func contextBudget() -> Int? {
        #if canImport(FoundationModels)
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            let reported = SystemLanguageModel.default.contextSize
            return reported > 0 ? reported : nil
        }
        #endif
        return nil
    }
}
```

`contextBudget()` returns `Int?` rather than defaulting to a constant, so callers must decide what to
do when the number is unknown. Apple's TN3193 states the on-device window as **4096 tokens per
session**; read `contextSize` when you can and treat 4096 as the documented figure, not as a value to
hardcode into your prompt budgeting.

### 17.5 `Sources/TextGen/PCCBackend.swift` — the 27 backend, fully gated

```swift illustrative
#if canImport(FoundationModels, _version: 2)

import FoundationModels
import Foundation

/// Private Cloud Compute. 27.0+, and requires the PCC entitlement.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct PCCBackend: TextGenerator {
    public let displayName = "Private Cloud Compute"
    public let requiresNetwork = true

    public init() {}

    public func generate(_ prompt: String) async throws -> String {
        let model = PrivateCloudComputeLanguageModel()
        let session = LanguageModelSession(model: model)
        return try await session.respond(to: prompt).content
    }

    /// Coarse quota state. The API exposes reached/below/approaching — not a percentage
    /// (forums 835974, FB23378161). Design for three states.
    public enum Quota: Sendable { case ok, approaching, exhausted, unknown }

    public func quota() -> Quota {
        let model = PrivateCloudComputeLanguageModel()
        let usage = model.quotaUsage
        if usage.isLimitReached { return .exhausted }
        if case .belowLimit(let info) = usage.status, info.isApproachingLimit {
            return .approaching
        }
        return .ok
    }
}

#endif  // canImport(FoundationModels, _version: 2)
```

> 🟡 **RECONSTRUCTED** — `quotaUsage`, `isLimitReached`, `.belowLimit(_)`, `isApproachingLimit` and
> `resetDate` are spelled as they appear in 🧑‍💻 `frozen Noema 3.5 snapshot`
> (`AppleFoundationModelAvailability.swift`), a shipping app built against the 27 SDK. That is
> compiling third-party code, not an Apple header, and no Apple documentation page in this corpus
> publishes these signatures. The *shape* — coarse states, a reset date, a
> `limitIncreaseSuggestion?.show()` affordance — is corroborated by forums thread 835974 and WWDC26
> session 241. **Verify against the SDK before shipping.** [Part 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/README.md)
> owns the PCC surface.

Note that the entire file — including `import FoundationModels` — is inside the gate. On a 26-SDK
build this file contributes nothing. That is `MLXFoundationModels`' empty library (§7), reproduced
deliberately, in your own code, where you control it.

### 17.6 `Sources/TextGen/Backends.swift` — the factory, the only assembly point

```swift prelude:guide-context
import Foundation

public enum Backends {

    /// Every backend this build, on this device, can actually use.
    public static func available() -> [any TextGenerator] {
        var result: [any TextGenerator] = []

        // Always attempt the on-device model; it self-reports if the OS is too old.
        if Capabilities.foundationModels26 {
            result.append(SystemBackend())
        }

        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            result.append(PCCBackend())
        }
        #endif

        return result
    }

    /// Why a backend you expected is missing. For diagnostics UI and bug reports.
    public static func explainMissingPCC() -> String {
        #if canImport(FoundationModels, _version: 2)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return "PCC is available."
        }
        return "PCC is compiled in, but this device is running an OS earlier than 27."
        #else
        return "PCC is not compiled into this build (built against a pre-27 SDK)."
        #endif
    }
}
```

`explainMissingPCC()` is the §12.2 idea generalised into a diagnostic. Three environments, three
distinct sentences, and a support engineer can tell them apart from a screenshot.

### 17.7 `Tests/TextGenTests/GateTests.swift` — asserting the negative

```swift prelude:external-module
import Testing
@testable import TextGen

// Tests that run on BOTH SDKs. Note the assertions are about the SHAPE of the
// build, which is exactly what a dual-SDK matrix needs to check (§16.3).

@Test func backendListIsNeverEmptyOnASupportedOS() {
    if Capabilities.foundationModels26 {
        #expect(!Backends.available().isEmpty)
    }
}

@Test func pccPresenceMatchesTheCompileTimeGate() {
    let names = Backends.available().map(\.displayName)
    #if canImport(FoundationModels, _version: 2)
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
        #expect(names.contains("Private Cloud Compute"))
    } else {
        #expect(!names.contains("Private Cloud Compute"))
    }
    #else
    // On a 26-SDK build the backend must be ABSENT. This is the assertion that
    // catches an over-gating or under-gating mistake, and it only runs in the
    // cell most teams never build.
    #expect(!names.contains("Private Cloud Compute"))
    #endif
}

@Test func diagnosticStringIsAlwaysMeaningful() {
    #expect(!Backends.explainMissingPCC().isEmpty)
    #expect(!Capabilities.summary.isEmpty)
}
```

The middle test is the important one, and note *how* it is written: unlike commit `3cbf928`'s 37
files, it is **not** gated out on the 26 SDK — it flips its expectation instead. That is the right
call for a test whose subject *is* the gate. Gate out tests that reference 27 symbols; keep and
invert tests that assert on the gate's effect.

### 17.8 If you are in an Xcode project rather than a package

Add the `[sdk=…27.*]` conditions from §5.1 to your target, define your own flag, and use it in
`Capabilities.swift` instead of (or alongside) `canImport`:

```swift illustrative
    public static var foundationModels27: Bool {
        #if MYAPP_SDK27
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }
```

and add the flag to the gate log so a misspelling (§4.6b) shows up immediately:

```swift illustrative
#if MYAPP_SDK27
#warning("BUILD GATE: MYAPP_SDK27 is SET")
#else
#warning("BUILD GATE: MYAPP_SDK27 is NOT SET")
#endif
```

Remember all five SDK-name lines (§5.2), `$(inherited)`, and that the flag must be set on **every**
target that contains gated code — app, extensions, widgets, and test targets. A widget that missed
the flag is a feature that works in the app and not on the Home Screen, with no error anywhere.

---

## 18. Checklist

Work down this list against your own repository. Each item names the section that explains it.

**Choosing gates**

- [ ] Every 27-only symbol reference is inside a **compile-time** gate — `canImport(FoundationModels,
      _version: 2)`, `canImport(CoreAI)`, `canImport(Evaluations)`, or your own SDK flag. (§1, §9)
- [ ] Every 27-only symbol reference is *also* inside `if #available(iOS 27.0, macOS 27.0,
      visionOS 27.0, *)`. Both, not either. (§1.3)
- [ ] Nothing that shipped in **26.0** (`@Generable`, `Tool`, `LanguageModelSession`,
      `supportsLocale(_:)`) or **26.4** (`contextSize`, `tokenCount(for:)`) is inside a 27 gate.
      (§11)[^supports-locale-floor]
- [ ] Modules that simply do not exist in the 26 SDK — Core AI, Evaluations, the Spotlight overlay —
      use plain `canImport(Module)`, not the underscored version form. (§9.2)
- [ ] If you build for watchOS, the outermost gate is bare `canImport(FoundationModels)`, because
      the module is absent from the watchOS 26 SDK. (§3.2)
- [ ] No `_underlyingVersion:` anywhere. It evaluates **true** on the 26 SDK. (§4.6c)
- [ ] `_version:` appears with the value **2** and no other value. No invented `3`, no `2.1`. (§4.4)

**Consistency**

- [ ] `grep -rn 'canImport(FoundationModels' . | sed 's/.*#if //' | sort | uniq -c` returns **one**
      distinct gate spelling. (§7.3)
- [ ] Every call site of a gated library symbol mirrors that library's gate token-for-token. (§7.1)
- [ ] Your **test targets** carry the same gates as the code they test. (§8.2)
- [ ] Every target that contains gated code has the compilation flag set — app, extensions, widgets,
      tests. (§17.8)
- [ ] All five (or more) `SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=…]` lines are present, device
      **and** simulator, with `$(inherited)`. (§5.2)

**Visibility**

- [ ] A permanent `#warning` gate log exists and CI greps it into an artifact. (§4.7, §16.2)
- [ ] A user-visible diagnostics string distinguishes *"unavailable on this device"* from
      *"unavailable in this build"*. (§12.2, §17.6)
- [ ] `@unknown default` on every `switch` over a framework enum. (§2.3)
- [ ] Gates are confined to a boundary layer; the rest of the app calls plain Swift. (§12.3, §12.4)

**Building and running**

- [ ] CI builds with **both** toolchains, selected via `DEVELOPER_DIR`, probed rather than
      hardcoded, with `fail-fast: false`. (§8.3, §16.2)
- [ ] At least one cell **loads** the binary on a **device** running the target OS. Compiling is not
      enough — §13 is a crash that only appears at load. (§13.2, §16.4)
- [ ] Cell B — your **existing shipped binary** on a **27 device** — is covered. (§16.1)
- [ ] No behavioural conclusion rests on a Simulator run. The Simulator punches out to the host
      macOS for inference. (§15.3)
- [ ] Framework calls pass **every argument explicitly**; no reliance on default arguments across a
      binary boundary during a beta cycle. (§13.2)
- [ ] Dependency versions are pinned by tag, and you re-read commit messages on every beta drop.
      (§14.2, §14.3)

**Known breakages to re-test each beta**

- [ ] watchOS FoundationModels `.swiftinterface` — does it still `public import CoreImage`? (§15.1)
- [ ] `foundation-models-utilities` — still 27.0-floor with no gates? (§15.2, §9.3)
- [ ] `updateUsage(input:output:metadata:)` — does the dylib export what the interface declares?
      (§13.3)

---

## 19. Declared gaps

Everything this guide could not verify, what it would take to close each, and what to do meanwhile.

### 19.1 What the 27 SDK reports for `-user-module-version` — ✅ RESOLVED 2026-07-29

**Answered, by exactly the command this section prescribed**, run against the Xcode 27.0 beta
(`27A5228h`) macOS 27.0 SDK and captured to
`notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface` (header line 3):

> **`FoundationModels` in the macOS 27.0 beta SDK declares `-user-module-version 2.0.62.1.402`.**

So `canImport(FoundationModels, _version: 2)` is **measured true** on the 27.0 SDK
(`2.0.62.1.402 >= 2.0.0`), no longer only Apple-asserted. Two refinements to §4.3's inference:
the **major-crossed-2-at-the-27-boundary** half is confirmed; the **minor-tracks-OS-minor** half
(`1.5.x` on 26.5 → so `2.4.x` on a 27.4) now looks *wrong in form* — the 27 module uses a
**five-component** scheme (`2.0.62.1.402`, the same shape `AppIntents` uses), so do not predict
future values from the OS version. For the record, the other captured 27-era dumps report:
`Vision 10.0.39`, `Speech 3600.74.1`, `AppIntents 301.0.45.4.401`, `CoreSpotlight 2454`,
`Evaluations 25061.1`, and the Core AI family `3600.79.1`.

**Safe default:** `_version: 2`, unchanged — now on measurement rather than assertion, and still
correct whatever the trailing components do, because the comparison is `>=`.

### 19.2 Whether the `_version:` spelling is stable

**Unknown, and by construction.** The leading underscore is Swift's marker for unofficial API. It
appears in **no** Apple documentation page, **no** WWDC session, and **no** Swift Evolution proposal
in this corpus. Its only Apple-authored appearances we can see are inside `ml-explore/mlx-swift-lm`
source, commit messages and CI comments.

**Resolves with:** an Apple documentation page, a Swift Evolution proposal formalising it, or a
compiler release note. **Safe default:** use it — Apple does, in a shipping package — but confine it
to one file (§17.2) so a future rename is a one-line change rather than a repo-wide sweep.

### 19.3 The `[sdk=…]` names for watchOS, tvOS and Mac Catalyst

**Partially verified.** iOS device/simulator, macOS, visionOS device/simulator are ✅ VERIFIED from
Noema's `project.pbxproj`. The other rows in §5.2's table follow Xcode's standard scheme but are not
attested by any file we read.

**Resolves with:** `xcodebuild -showsdks` on a machine with the relevant platforms installed.
**Safe default:** run that command and copy the exact strings; do not trust a table, including this
one.

### 19.4 Whether the watchOS `CoreImage` bug is fixed

**Unknown as of 2026-07-28.** Reported against **watchOS 27 beta 2**; Apple's reply was *"This is a
known bug"* and the thread has no follow-up.

**Resolves with:** `grep -n 'public import' <watchOS 27 SDK>/…/arm64e-apple-watchos.swiftinterface`.
**Safe default:** §15.1 — gate watchOS out of the Foundation Models path, and re-check every beta.
**There is no workaround** if you need it working today.

### 19.5 Whether the `updateUsage` interface/dylib mismatch is fixed

**Unknown as of 2026-07-28.** The fix in `mlx-swift-lm` is a deletion with a TODO, not a
version-conditional, so the repository does not signal when it becomes safe.

**Resolves with:** `nm -gU` against the FoundationModels dylib on a current 27 build, compared with
the matching SDK's `.swiftinterface`. **Safe default:** never rely on default arguments in framework
calls during a beta cycle; pass everything explicitly.

### 19.6 Whether `foundation-models-utilities` will ever be dual-SDK

**Unknown.** Issues are disabled, PRs are not accepted, there is no roadmap, and the 27.0 platform
floor is unconditional.

**Resolves with:** an Apple statement or a commit adding gates. **Safe default:** treat it as
permanently 27-only; vendor the pieces you need (Apache 2.0, zero dependencies) if you must support
26.

### 19.7 Whether `mlx-swift-lm`'s integration workflow still runs on a schedule

**Unknown.** Commit `5fbb130` describes it as running nightly; the file at `3cbf928` has only
`workflow_dispatch`. Immaterial to your build, but it is the difference between "Apple's nightly
caught this" and "someone noticed" as the origin story of §8. **Resolves with:** the repository's
current `.github/` tree.

### 19.8 What we deliberately did not attempt

- **A `_version:` ladder for future OS versions.** §4.4. One predicate, one boundary.
- **Any claim about the 27 SDK measured on this machine.** Every 📏 measurement in this guide is a
  **26.5 SDK** measurement, stated as such. The machine that produced them is macOS 26.5.2 (25F84) /
  Xcode 26.6 (17F113), 2026-07-28.
- **A reconciliation of the retired 4096-vs-8192 context-window conflict.** Apple's TN3193 says
  4096; the unreproduced third-party 8192 comment remains only as historical provenance.
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) owns the resolution. Read `contextSize`.

---

## Sources

**Apple first-party compiling code** (strongest evidence class; all read from local clones):

- `ml-explore/mlx-swift-lm` at HEAD `3cbf928b5eb24190e8952725699ae6a3bb02824d` — *"Integration tests:
  build on both macOS 26 and 27 SDKs (#464)"*, Charlie Le `<charlie_le@apple.com>`, 2026-07-24.
  Also commits `1c86cc1` (the load-time SIGSEGV), `2a76e56` (the SamplingMode rename), `9cd1a48`,
  `5fbb130`, `d242429`. Files: `Package.swift`, `Libraries/MLXFoundationModels/MLXLanguageModel+Availability.swift`,
  `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, `Libraries/MLXHuggingFace/FoundationModelsMacros.swift`,
  `.github/workflows/integration_tests.yml`, `.github/workflows/pull_request.yml`,
  `scripts/verify-docs.sh`, `.spi.yml`, `.swift-format`, `CONTRIBUTING.md`, `README.md`.
- `apple/foundation-models-utilities` at `376ca60` (tag `1.0.0-beta3`, 2026-07-10) — `Package.swift`,
  `Sources/FoundationModelsUtilities/**`, and commit `376ca60`'s message, which doubles as a
  beta-1 → beta-3 framework changelog.

**SDKs on disk** (📏 measured by us, macOS 26.5.2 build 25F84 · Xcode 26.6 build 17F113 ·
2026-07-28): `MacOSX26.5.sdk`, `iPhoneOS26.5.sdk`, `WatchOS26.5.sdk`, `AppleTVOS26.5.sdk`,
`XROS26.5.sdk` — framework inventories and `FoundationModels.swiftinterface`
`swift-module-flags` lines; `swiftc -typecheck` probes of `canImport` behaviour.

**Apple documentation:** Technical Note **TN3193**, *"Managing the on-device foundation model's
context window."* iOS/iPadOS 27 release notes (known issue **177684296**, PCC in simulators).

**Apple-staff forum answers:** 835987 (watchOS `CoreImage`: *"This is a known bug"*), 831404 (the
Simulator punch-out explanation), 831998 (PCC not in simulators), 835165 (`SkillActivation` build
failure — unresolved), 836760 (Siri-enablement gating: confirmed a bug; EU availability), 836810
(no Required Device Capability), 835974 (coarse PCC quota, FB23378161), 835211 (availability tied
to Siri toggle, unanswered).

**WWDC26 transcripts:** session 241 (the `LanguageModel` abstraction layer; watchOS via PCC; the
iOS 26.4 context APIs), session 246 (`SpotlightSearchTool` and the `_CoreSpotlight_FoundationModels`
overlay), sessions 319 / 339 (`ContextOptions`, PCC).

**Community, attributed:** [frozen Noema 3.5 snapshot](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/467d3cc496248af2928d92f8d330ba4a8457f0f8/notes/repos/noema-ios.md) (Noema 3.5, MIT) — the
`SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=…27.*]` pattern, the three-layer gate, the `Any`-erased
stored properties, the two-case error enum, the 26.4 over-gating comment, and the
`ci_pre_xcodebuild.sh` `.swiftinterface` workaround. All preserved in the retained research note; never presented as
Apple statements.

[^supports-locale-floor]: The authoritative Xcode 26.5 interface places [`SystemLanguageModel.supportsLocale(_:)`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface#L572-L591) in the OS 26.0 declaration; the following extension is the distinct OS 26.4 context-introspection surface.

---

**Next:** [17.5 — Core ML to Core AI: what moves, what stays, and how](05-coreml-to-coreai.md) ·
**Back to:** [Part 17 README](../README.md)
