# Toolchain and asset compatibility: when your build artifacts stop working

**Part 17 · Migration from pre-iOS 27 · Reference 06**

**Version floor.** This guide assumes you have already shipped or exported something against the
**26.x** generation and are moving to **iOS/iPadOS/macOS 27** and **Xcode 27**. The specific floors
that matter: **Core AI is 27.0-only** on every platform, with no 26.x back-deployment; `coreai-torch`
**0.4.1** is the first release whose assets survive **iOS/macOS 27 beta 2 and later**; `coreai-core`
is pinned at **1.0.0b2**; AOT compilation needs **Xcode 27** plus the separately-downloaded **Metal
Toolchain**, and `xcrun coreai-build` runs on **macOS 27** hosts; `mlx-swift-lm` **`main` is 3.x**
and breaks 2.x call sites; `apple/foundation-models-utilities` has shipped only **prerelease** tags.
Everything in this guide that carries a number was measured on **beta** software, and every number
says who measured it.

> ⚠️ **SILENT FAILURE — this guide is nothing but silent failures.** The rest of Part 17 is about
> source-level migration: renamed types, withdrawn capabilities, `catch` clauses that stop firing.
> This guide is about the other half, the half nobody warns you about — **your build artifacts have
> compatibility constraints that are independent of your source.** Not one of the defects below is
> visible in a diff. Two of them do not produce a log line. One of them produces a *successful*
> compile that a device then refuses to load. And the single most expensive one produces a working,
> loadable, correct model that is **2.2× slower than the one you measured last week**, from a
> byte-identical command.

---

## What this covers

The thesis first, because everything else follows from it:

> **An `.aimodel` is a build artifact, not a pure function of your recipe.**
> Treat it like a compiled binary — version-stamp it, archive it, and benchmark exactly the bytes
> you intend to ship.

That sentence is not ours. It is the conclusion a community engineer reached after re-running an
export command that had produced a 1,116 tok/s artifact and getting a 500 tok/s one, with the same
source checkout, the same registry preset, the same wheel versions and the same machine. It is
quoted in full in §4.

What follows:

- **§1–2 — The artifact inventory.** Five distinct classes of build output live in a modern
  on-device AI project, and each one is invalidated by a different thing. Most teams can name two
  of them.
- **§3 — Incident 1: the `coreai-torch` 0.4.0 IR-location break.** Assets converted with 0.4.0 stop
  loading on 27 beta 2 and later. Repacking does not fix it, wheel-pinning does not fix it, and
  re-AOT does not fix it — but `coreai-build inspect` still reads the asset perfectly, which is what
  makes the whole thing feel recoverable when it is not. Includes the `producer`-field audit that
  finds every affected asset in one `find`, the `strip_debug_info` repair, and the chicken-and-egg
  problem in the repair (you need one wheel generation to *parse* the asset and a different one to
  *stamp* it).
- **§4 — Incident 2: the macOS 26 → 27 export-lowering regression.** Same recipe, same wheels, same
  weights, same device: **~2.2× slower and roughly twice the memory**, because the
  dequantisation-folding decision consults the *running OS*, not the wheel. Nothing errors, nothing
  warns. This section carries the lesson that ought to change how you run a build farm: **the export
  host's OS version is an input to the model's performance.**
- **§5 — Specialization artifacts are tied to the device *and the OS version*.** Every OS update
  invalidates every cache entry your app owns, regardless of cache policy, and your users pay the
  first-load cost again. There is a supported way to notice this before the user does.
- **§6 — Bookmarks stop resolving after a purge, a manual delete, or an OS update** — and
  `AIModel(resolvingBookmark:)` returns **`nil`** rather than throwing, so on the OS-update path it
  lands in whatever `else` branch you wrote six months ago and never tested.
- **§7 — `coreai-build compile` exits 0 for architectures a device will reject.** A green build is
  not validation. Only a device load validates the architecture choice.
- **§8 — `metadata.json`'s `compression` field records the *request*, not the *result*.**
  Quantisation failures are swallowed with a `logger.warning`, so you can ship a 4×-too-large asset
  whose metadata claims 4-bit. The only signal is file size.
- **§9 — Package-level migrations.** `mlx-swift-lm` 2.x → 3.x (the tokenizer/downloader decoupling,
  what it breaks, and where the upgrade doc is itself stale); `foundation-models-utilities`, whose
  README dependency line resolves to *nothing*; and `apple/coreai-models` commit #123, an example of
  the ecosystem chasing the same Foundation Models rename that guide 17.3 documents.
- **§10 — The artifact provenance checklist.** What to record alongside every shipped model so that
  the next time something like this happens you can identify the blast radius in minutes instead of
  days. With the verified API for stamping it into the asset itself.
- **§11–12 — Triage table and the evidence ledger.**

## What this does *not* cover

- **Source-level API migration.** `GenerationError` → `LanguageModelError`, the adapter sunset,
  dual-SDK conditional compilation — guides [17.2](02-adapter-sunset.md),
  [17.3](03-error-taxonomy-migration.md) and [17.4](04-dual-sdk-builds.md).
- **How to convert a model in the first place.** `TorchConverter`, op coverage, externalization —
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md).
- **Which compression scheme to pick.** [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
  §8 here is only about the metadata field lying to you, not about the choice.
- **The specialization API surface in depth** — `AIModelCache`, `Policy`, `PurgeConditions`,
  `SpecializationOptions`. That is
  [Part 7 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md),
  and §5–6 here assume you have read it or will.
- **Distribution mechanics** — Background Assets, per-architecture asset packs, staged rollout.
  [Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md).

## What you need

- A shell, and the ability to run `find` and `python3 -c` over the tree where your `.aimodel`
  bundles live. §3's audit is four lines and you should run it before you read §4.
- **Xcode 27** plus the **Metal Toolchain** component if you AOT-compile. `xcrun coreai-build` is a
  macOS 27 host tool — and the component is not optional decoration: `coreai-build` **lives in the
  Metal Toolchain**, not in Xcode-beta.app (resolved 2026-07-31 — the app bundle carries only the
  `aimodelc` stub, which is why our 2026-07-29 check without the optional component could not
  resolve `coreai-build`); see §7.
- For the §3 recovery: the ability to create **two** isolated Python virtual environments with
  *different* `coreai-core` wheel generations in them. This is not optional; §3.6 explains why.
- A **real device** for anything in §5, §6 or §7. Specialization is per-hardware and per-OS. A
  Simulator result is not a result — and the `CoreAI` framework is absent from the iOS Simulator SDK
  entirely (§7).
- Somewhere to put an artifact archive. §10 is not useful retroactively.

---

## Contents

1. [The thesis: your artifacts are not a pure function of your recipe](#1-the-thesis-your-artifacts-are-not-a-pure-function-of-your-recipe)
2. [The artifact inventory: five classes, five invalidation rules](#2-the-artifact-inventory-five-classes-five-invalidation-rules)
3. [Incident 1 — the `coreai-torch` 0.4.0 IR-location break](#3-incident-1--the-coreai-torch-040-ir-location-break)
   - [3.1 What it looks like](#31-what-it-looks-like)
   - [3.2 The root cause, and why deep models fire it](#32-the-root-cause-and-why-deep-models-fire-it)
   - [3.3 ⚠️ Why it is vicious: `inspect` still works](#33-️-why-it-is-vicious-inspect-still-works)
   - [3.4 The negative list: four things that do not fix it](#34-the-negative-list-four-things-that-do-not-fix-it)
   - [3.5 The audit: the `producer` fingerprint](#35-the-audit-the-producer-fingerprint)
   - [3.6 The fix, and the chicken-and-egg inside it](#36-the-fix-and-the-chicken-and-egg-inside-it)
   - [3.7 The full recovery recipe](#37-the-full-recovery-recipe)
   - [3.8 What cannot be recovered](#38-what-cannot-be-recovered)
   - [3.9 Preventing a recurrence: `Mode.RELEASE`](#39-preventing-a-recurrence-moderelease)
4. [Incident 2 — the macOS 26 → 27 export-lowering regression](#4-incident-2--the-macos-26--27-export-lowering-regression)
   - [4.1 The A/B](#41-the-ab)
   - [4.2 The op-level forensics](#42-the-op-level-forensics)
   - [4.3 The mechanism: one wheel, two native stacks](#43-the-mechanism-one-wheel-two-native-stacks)
   - [4.4 The decisive negative result](#44-the-decisive-negative-result)
   - [4.5 ⚠️ The lesson: the export host's OS version is an input to the model's performance](#45-️-the-lesson-the-export-hosts-os-version-is-an-input-to-the-models-performance)
   - [4.6 The detection recipe](#46-the-detection-recipe)
   - [4.7 The operational rule](#47-the-operational-rule)
   - [4.8 🔴 Status unknown](#48--status-unknown)
5. [Specialization artifacts are tied to the device *and the OS version*](#5-specialization-artifacts-are-tied-to-the-device-and-the-os-version)
6. [Bookmarks stop resolving — into a silent `else`](#6-bookmarks-stop-resolving--into-a-silent-else)
7. [`coreai-build compile` exits 0 for architectures a device will reject](#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject)
8. [`metadata.json`'s `compression` field records the request, not the result](#8-metadatajsons-compression-field-records-the-request-not-the-result)
9. [Package-level migrations](#9-package-level-migrations)
   - [9.1 `mlx-swift-lm` 2.x → 3.x](#91-mlx-swift-lm-2x--3x)
   - [9.2 `foundation-models-utilities`: the dependency line that resolves to nothing](#92-foundation-models-utilities-the-dependency-line-that-resolves-to-nothing)
   - [9.3 `apple/coreai-models` #123 — the ecosystem chasing the same rename](#93-applecoreai-models-123--the-ecosystem-chasing-the-same-rename)
10. [The artifact provenance checklist](#10-the-artifact-provenance-checklist)
11. [Triage: what to check, in what order](#11-triage-what-to-check-in-what-order)
12. [Sources and evidence ledger](#12-sources-and-evidence-ledger)

---

## 1. The thesis: your artifacts are not a pure function of your recipe

Software engineers carry a strong intuition, learned from decades of build systems, that a build is
a function: same inputs, same outputs. Deterministic builds are a thing people work hard to achieve
and mostly get. Reproducible container images are a thing. `Package.resolved` exists so that a
`swift build` on your machine and a `swift build` in CI produce the same program.

On-device model conversion does not work like that, and the 26 → 27 transition is where a lot of
teams discovered it.

Three separate facts, each of which is verified below, combine into the problem:

1. **The conversion toolchain writes version-sensitive metadata into the asset.** `coreai-torch`
   0.4.0 embedded PyTorch stack traces as MLIR `fused` locations. That was fine on iOS/macOS 27
   beta 1 and became a hard load failure on beta 2 — a change in the *consumer*, not the producer,
   retroactively invalidating artifacts that were already published (§3).
2. **The conversion toolchain consults the running OS when it lowers.** The decision to fold
   dequantisation into a native quantised-`Linear` op, versus emitting explicit dequantise-then-matmul
   chains, is made by pass code that queries the platform underneath it. Upgrade the export box's OS
   and the same command emits a different program (§4).
3. **The device-side artifact is regenerated on every OS update, and none of it is under your
   control.** Specialization output is *"tied to that device's hardware and OS version"*, and
   Apple documents the invalidation as unconditional (§5).

Put together: **your `.aimodel` bundle, your `.aimodelc` compiled variant, and the device-side
specialized asset each have an independent compatibility window**, and none of those windows is
described anywhere in your source tree.

> ✅ **VERIFIED — the framing is Apple's too, at least for the last of the three.**
> Apple, *Managing model specialization and caching*, verbatim: *"When you load a `.aimodel` file
> with `AIModel`, Core AI performs **specialization**, the process of optimizing the model for the
> current device's hardware. The `.aimodel` file contains your model in a **portable format that
> works across Apple devices**. Before the model can run, Core AI specializes it for the current
> device, producing **executable code tied to that device's hardware and OS version**."*

Read the phrase *"portable format that works across Apple devices"* carefully. It is a claim about
**devices**, not about **toolchain versions**. Nothing in Apple's documentation claims that a
`.aimodel` produced by one converter release loads on a runtime from a later release, and §3 is the
case where it did not.

### The two shapes of the problem

It is worth separating them, because the diagnostics are completely different.

| | **Hard incompatibility** (§3) | **Silent behaviour drift** (§4) |
|---|---|---|
| Symptom | Load fails, compile fails | Nothing fails |
| Diagnostic | An error string you can grep for | A benchmark, or nothing |
| Blast radius | Everything built with the bad producer | Everything built on the wrong host OS |
| How you find out | Users' crash reports, or your CI | A user says the app "feels slower" |
| How long it takes to fix | Hours per model | You do not know it needs fixing |
| Which is worse | | **This one.** |

A hard incompatibility is a bad week. Silent behaviour drift is a bad quarter, because there is no
moment at which anyone is forced to look. This is the reason §10 exists.

### A note on evidence

Both incidents in this guide are **community-documented**, and this guide attributes them as such
every time they are mentioned. They are not Apple statements and they are not our measurements.
Specifically:

- **Incident 1** has an Apple root-cause statement behind it — `apple/coreai-torch` issue #37 and
  the v0.4.1 release notes — plus an Apple maintainer's repair recipe in issue #44. The *operational*
  detail (the negative list, the `producer` audit, the two-wheel recovery) is a single community
  engineer's forensics, published in a public repository, and reproduced here with attribution.
- **Incident 2** has **no** Apple acknowledgement at all. It is one engineer's A/B on one Mac and one
  iPhone, on beta software, dated 2026-06-11. The mechanism is well argued and the negative control
  is a good one, but treat the *magnitude* as an order-of-magnitude claim and re-measure on your own
  hardware before you make a decision costing more than a day.

Where this guide quotes an Apple documentation page, a header, or a file in a shipping Apple
repository, it says so and marks the claim ✅ **VERIFIED**. Where it quotes a community engineer, it
names them as community-measured. The distinction is load-bearing in this guide more than most.

---

## 2. The artifact inventory: five classes, five invalidation rules

Before the incidents, an inventory. Most projects can name the first two entries in this table and
are surprised by the rest.

| # | Artifact | Produced by | Where it lives | Invalidated by |
|---|---|---|---|---|
| 1 | **`.aimodel`** — portable source asset (a *directory*) | `coreai-torch` → `AIProgram.save_asset()` | Your build output; your CDN; the app bundle | The **producer version**, when a newer runtime rejects its IR (§3). Also the export **host OS**, in the sense that its *contents* differ (§4) |
| 2 | **`.aimodelc`** — AOT-compiled, per-architecture (also a *directory*) | `xcrun coreai-build compile` | Background Assets; the app bundle | The **target architecture** — and the compiler exits 0 whether or not you chose right (§7). Also toolchain generation: beta-2-or-earlier `.aimodelc` need a beta-3 recompile |
| 3 | **Specialized cache entry** | Core AI, on device | `AIModelCache` — location undocumented | **Every OS update, unconditionally.** Also source-asset change/delete and storage pressure, depending on policy (§5) |
| 4 | **Bookmark `Data`** | `AIModel.bookmarkData` | Your `UserDefaults`, your database | Whatever invalidates #3 — and it fails by returning `nil`, not throwing (§6) |
| 5 | **`metadata.json`** — the bundle manifest | `coreai_models.export.bundle` (or you) | Next to the `.aimodel` inside the bundle directory | Nothing invalidates it, which is the problem: it records **requests**, and can outlive their truth (§8) |

Two structural facts about #1 and #2 that trip people up constantly and are worth stating once:

> ✅ **VERIFIED** — **`.aimodel` is a directory, not a file**, and so is `.aimodelc`.
> `apple/coreai-models` treats it as a directory throughout, and its overwrite path calls
> `shutil.rmtree` on it. `AIProgram.save_asset(path)` writes a bundle containing `main.mlirb`
> (the IR bytecode), `main.hash`, and `metadata.json`. A compiled `.aimodelc` contains
> `main-<arch>.mlirb` plus a `main-<arch>-delegates` directory.
>
> Consequences you will meet: `cp` needs `-R`; a file-oriented checksum script silently checksums
> nothing; and "delete the model" means `removeItem(at:)` on a directory URL.

> ✅ **VERIFIED** — Apple, `AIModel.init(contentsOf:options:)` parameter documentation: `modelURL` is
> *"The URL of a `.aimodel` **or `.aimodelc`** file"*. **One initializer takes both.** That is
> convenient and it is also why a mis-targeted `.aimodelc` produces a runtime failure rather than a
> compile-time one — the type system cannot help you here (§7).

### The one that surprises people

Class #3 is the one most teams have never thought about as an *artifact* at all, because it is
produced on the user's device and they never see it. But it behaves exactly like a build output:
it is expensive to produce, it is version-locked, and it is thrown away on a schedule you do not
control.

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, on `AIModelCache.Policy`,
> verbatim: *"**Regardless of policy, the system always purges assets when the OS updates**, as
> specialized assets are OS-version specific."* The same sentence is repeated on
> `Policy.PurgeConditions`: *"The system always purges assets on OS update regardless of these
> conditions."*

And the cost of regenerating it is not small:

> **Community-measured** — `apple/coreai-models`' own official Qwen3-4B iOS ANE preset, a 3 GB
> `.aimodelc`, on **iPhone 17 Pro / iOS 27 beta**: cold load **194 s**, warm load **0.46 s**.
> Same source, same protocol (512-token prompt / 1024-token generation, 5 trials). Measured by the
> author of the `coreai-model-zoo` community repository; attribute as community-measured, on beta
> software.

194 seconds is what an OS update costs one of your users, once, for one model, if you have not
planned for it. §5 is how you plan for it.

### How the classes chain

```
PyTorch checkpoint
   │
   │  coreai-torch TorchConverter            ← producer version is recorded (§3)
   │  AIProgram.optimize()                   ← lowering consults the HOST OS (§4)
   │  AIProgram.save_asset()
   ▼
MyModel.aimodel/                             ← class 1: portable source (a directory)
   ├── main.mlirb        (IR bytecode)
   ├── main.hash
   └── metadata.json     ("producer": "coreai-core 1.0.0b2", …)
   │
   │  xcrun coreai-build compile --architecture h18p …
   │      ← exits 0 for ANY arch you name (§7)
   ▼
MyModel.h18p.aimodelc/                       ← class 2: per-architecture AOT output
   ├── main-h18p.mlirb
   └── main-h18p-delegates/
   │
   │  on device: AIModel(contentsOf:) or AIModel.specialize(…)
   ▼
a cache entry in AIModelCache                ← class 3: device + OS-version locked (§5)
   │
   │  model.bookmarkData
   ▼
Data in UserDefaults                         ← class 4: resolves to nil when class 3 dies (§6)
```

Every arrow in that diagram is a place where a version mismatch can be introduced, and only the
first one produces an error message you would recognise.

---

## 3. Incident 1 — the `coreai-torch` 0.4.0 IR-location break

> **Attribution.** The root cause and the repair are Apple's, from
> [`apple/coreai-torch` issue #37](https://github.com/apple/coreai-torch/issues/37), the
> [v0.4.1 release notes](https://github.com/apple/coreai-torch/releases/tag/v0.4.1), and
> [issue #44](https://github.com/apple/coreai-torch/issues/44). The operational forensics — the
> negative list, the `producer` audit, the two-wheel recovery — are **community-documented** by the
> maintainer of a ~60-model community model zoo, published as
> `knowledge/coreai-torch-041-ir-incident.md` in the `coreai-model-zoo` repository, dated
> **2026-07-18** with an update on **2026-07-21**. Quotations below are from that document and from
> the GitHub threads. Nothing here is a measurement of ours. ✅ **Both GitHub issues are now
> closed as completed** — #37 on 2026-07-13, #44 on 2026-07-24 (checked via `gh`, 2026-07-29) —
> consistent with the incident being resolved by the 0.4.1 toolchain and the repair recipe below.

### 3.1 What it looks like

The community forensics document opens with the scope claim, verbatim:

> **Community-documented** — *"Every `.aimodel` converted with `coreai-torch` **0.4.0** stops
> loading on **iOS/macOS 27 beta 2 and later**. It runs on beta 1."*

On beta 2 and later, **both** the runtime load path (`AIModel.load` in Python, `AIModel(contentsOf:)`
in Swift) **and** the host compile path (`xcrun coreai-build compile`) abort with the same three
lines:

```
error: expected AICode versioned location, got: loc(fused<...>)
error: Failed to convert to versioned IR
LLVM ERROR: cannot unwrap empty `odiec_module_t`
```

The full, unabbreviated form, reproduced from the reporter's issue on `apple/coreai-torch`, shows
what the offending location actually contains — and it is immediately recognisable as your own model:

```
loc(fused<{call_stack = ["PixelShuffle$1", "Upsampler$1", "Sequential$19", "EDSR$1"],
  identifiers = ["pixel_shuffle"]}>[...]): error: expected AICode versioned location, got: loc(fused<...>)
loc(...): error: Failed to convert to versioned IR
LLVM ERROR: cannot unwrap empty `odiec_module_t`
```

Three things to notice about that error, because they determine how you will experience the failure:

1. **`LLVM ERROR:` is a hard abort, not a Swift throw.** In the Python runtime it takes the process
   down. In `coreai-build` you get a non-zero exit and no output. There is no `catch` that helps you.
2. **The `call_stack` names your PyTorch module hierarchy.** `EDSR$1` → `Sequential$19` →
   `Upsampler$1` → `PixelShuffle$1`. That is the fingerprint of the bug: the location is a *nested
   fused* location built from a torch stack trace.
3. **It fires at compile/convert time on the consumer side**, which is why an asset that shipped
   perfectly happily in June started failing in July with no change on your side at all.

The same error text also showed up in `apple/coreai-models` issue #77, on a FLUX export running on
iPadOS beta 3, where the maintainer's answer was blunt:

> **Community-documented, quoting an `apple/coreai-models` maintainer (@stikves), verbatim:**
> *"`LLVM ERROR: cannot unwrap empty odiec_module_t` — Yes, **Beta 3 needs new exports and clean
> re-compile**"*

### 3.2 The root cause, and why deep models fire it

Apple's own statement, from issue #37 and the v0.4.1 release notes, as quoted in the community
forensics:

> **Root cause (Apple)**, verbatim: *"0.4.0 baked PyTorch stack traces into the IR as MLIR `fused`
> locations; the beta-2 compiler no longer parses that nested form. **It fires on deep module
> hierarchies.**"*

You can see exactly where that came from in the shipping `coreai-torch` source, which makes this one
of the rare cases where an incident's cause is readable in a public repository.

> ✅ **VERIFIED** — `apple/coreai-torch` at `0.4.1` (`coreai_torch/converter.py:110-138`), the
> converter's debug-recorder factory:
>
> ```python
> include_stack_trace = mode == TorchConverter.Mode.DEBUG
> debug_config = _DebugInfoRecorder.Config(
>     include_stack_trace=include_stack_trace,
>     verify_debuginfo_locations=_get_verify_debuginfo_locations_enabled(),
> )
> return _DebugInfoRecorder(config=debug_config)
> ```
>
> and the constructor default (`converter.py:140`):
>
> ```python
> def __init__(self, *, mode: "TorchConverter.Mode" = Mode.DEBUG) -> None:
> ```

**`Mode.DEBUG` is the default.** The `Mode` docstring, verbatim from the same file:

> ✅ **VERIFIED** — `coreai_torch/converter.py`, `TorchConverter.Mode` docstring:
> *"Controls the level of debug information embedded in the converted asset.
> `RELEASE`: Lightweight mode that records only operation IDs without stack traces.
> `DEBUG`: Includes full torch stack traces for comprehensive source mapping and debugging."*

So the default conversion mode embeds full torch stack traces, on purpose — that is what makes the
Core AI Debugger's "trace this op back to your Python source" feature work. On 0.4.0 those traces
were serialised in a nested `fused` location form that beta 2's IR reader stopped accepting.

> ⚠️ **Note what this means about the shape of the defect.** It was not a bug in *your* model, and
> it was not a bug in the weights. The payload — the actual program, the actual tensors — was
> completely fine the whole time. What broke was **metadata that exists only to make debugging
> nicer**. That is why the repair in §3.6 is cheap, and it is also why the failure feels so
> disproportionate when you hit it.

> 🔴 **GAP — the exact IR-format change is not public.** Nobody outside Apple has published the
> before/after grammar for AICode versioned locations, and `coreai-core`'s MLIR reader is a binary
> wheel, not source. We can tell you what the reader rejects (nested `fused<...>` with a
> `call_stack` attribute) and what it accepts (locations carrying a `coreai` operation ID), because
> `strip_debug_info`'s source shows what it writes — but not the formal rule.
> **What would resolve it:** an Apple statement, or the `coreai-core` MLIR dialect definition.
> **Safe default meanwhile:** do not attempt to hand-edit `main.mlirb`. The only supported repairs
> are re-conversion and `strip_debug_info`.

### 3.3 ⚠️ Why it is vicious: `inspect` still works

This is the part that costs teams a day, and it is worth its own callout.

> ⚠️ **SILENT FAILURE (inverted) — a tool that succeeds on a broken asset.**
> `xcrun coreai-build inspect` reads a 0.4.0 asset **perfectly**. Function signatures print.
> Inputs, outputs and states print. Weight ops and dtypes print. Nothing warns. The community
> forensics states the consequence in one sentence, verbatim:
>
> > *"`coreai-build inspect` still reads the asset fine, which makes it look recoverable. It isn't."*
>
> And in the GitHub thread, the same reporter spelled out the reasoning that misleads you:
>
> > *"function signatures, inputs/outputs and states all print correctly. So the payload itself
> > isn't corrupt; only the location metadata is in the pre-0.4.1 form."*
>
> That reasoning is **correct** and the conclusion people draw from it — "so I can repack it" — is
> **wrong**, because every repacking path preserves the locations (§3.4). The takeaway for your
> tooling:
>
> **`coreai-build inspect` succeeding is not evidence that a model will load or compile.** If you
> have a CI step that "validates" assets by inspecting them, that step validated nothing during this
> incident. Replace it with a *load*, and preferably with a load-and-generate (§3.7).

The general form of this lesson is worth carrying beyond this one incident: **in this stack,
read-only introspection paths and execution paths do not share a code path.** `AIModelAsset` exists
precisely so you can inspect without specializing — Apple says so explicitly:

> ✅ **VERIFIED** — Apple, `AIModelAsset` overview: *"Use a model asset to inspect a model's
> structure and metadata **without specializing it** for a specific device. This lets you query model
> information without performing specialization, **which is an expensive operation**."* And on
> `isValid(at:)`, verbatim: *"This checks that: the URL is a file URL; the extension is one of the
> known model asset extensions; the model contains either a source program or a derived artifact."*

Read `isValid(at:)`'s three checks again. It is a **file-shape** check. It does not compile anything,
it does not specialize anything, and it will happily return `true` for an asset that cannot be
loaded. It is a good cheap pre-flight against a truncated download; it is not a health check.

### 3.4 The negative list: four things that do not fix it

The community document publishes an unusually valuable negative list — four repair strategies that
a competent engineer would try, in the order they would try them, all of which fail. All four are
stated as verified in the source document.

> **Community-documented — "Things that do NOT work (all verified)", verbatim:**
>
> - **`coreai-build package`** — *"re-emits the asset (producer bumps) but leaves IR locations
>   untouched; compile fails identically."*
> - **Pinning `coreai-core` back to `1.0.0b1`** — *"the gate is OS-side, not in the wheel."*
> - **Re-AOT with the beta-3 toolchain** — *"dies at the same op."*
> - **`coreai-build inspect` still reads the asset fine** — *"which makes it look recoverable. It
>   isn't."*

Take them one at a time, because each one teaches something.

**`coreai-build package` bumps the producer stamp without repairing the IR.** This is the most
dangerous of the four, because it *changes the exact field you would audit on*. The reporter
observed the producer stamp updating to `coreai-build-3600.75.3` while the compile failed
identically. So if you repack first and audit second, your audit (§3.5) will tell you the tree is
clean and it will be wrong.

> ⚠️ **Order matters: audit before you repack.** Run the `producer` audit in §3.5 on the tree as it
> stands today. `coreai-build package` destroys the evidence you need.

**Wheel-pinning does not help the runtime.** This is the finding that everybody's instinct reaches
for — "the old wheel produced it, so the old wheel must consume it" — and it is wrong for the
*runtime* path, because on 27 beta 2+ the loader is the OS framework, not the wheel. Hold that
thought; §3.6 contains a precise, important correction to it for the *authoring* path.

**Re-AOT does not launder the asset.** `coreai-build compile` consumes the same IR the runtime does,
through the same versioned-IR conversion. There is no "recompile it and the problem goes away" move
here, unlike some binary-compatibility situations where a rebuild is the whole fix.

**And `inspect` succeeds** — covered above.

There is one more thing that does not work, and it is not on the list because it is not a repair
attempt at all — it is a *packaging* landmine that silently un-does a correct fix:

> ⚠️ **SILENT FAILURE — the shadowing `egg-info`.** Community-documented, verbatim:
> *"**Never run python with the coreai-torch clone as cwd**: its `coreai_torch.egg-info` (0.4.0)
> shadows the installed 0.4.1 via `sys.path[0]`, so **exports silently use 0.4.0**."*
>
> This one produces no error at any point. You upgrade the wheel, you re-export, the export
> succeeds, and you have produced a fresh batch of broken assets. There is no message. The only way
> you find out is by auditing the output (§3.5) or by trying to load it.
>
> **Defend against it structurally**, not by remembering: run every export from a directory that is
> not a checkout of `coreai-torch`, and assert the version at the top of your export script:
>
> ```python
> import coreai_torch
> from packaging.version import Version
>
> assert Version(coreai_torch.__version__) >= Version("0.4.1"), (
>     f"coreai-torch {coreai_torch.__version__} produces assets that will not load on "
>     f"iOS/macOS 27 beta 2+. Check for a shadowing coreai_torch.egg-info in cwd: "
>     f"{coreai_torch.__file__}"
> )
> ```
>
> Printing `coreai_torch.__file__` in the failure message is the part that actually saves you — it
> shows you immediately whether you are importing from `site-packages` or from a checkout.
>
> ✅ **VERIFIED** — `coreai_torch/__version__.py` in the shipping repo reads `__version__ = "0.4.1"`,
> and `coreai_torch/__init__.py` re-exports it, so `coreai_torch.__version__` is a real, readable
> attribute. The `egg-info` shadowing behaviour is community-documented, not Apple-stated, but it is
> ordinary Python `sys.path` semantics.

### 3.5 The audit: the `producer` fingerprint

Here is the good news in an otherwise unpleasant section. You can identify every affected asset in
your tree with a single field, without loading anything, without a device, and without guessing from
timestamps.

> **Community-documented, verbatim:** *"A 0.4.1-converted `.aimodel/metadata.json` carries a
> `producer` field; a 0.4.0 one does not:*
>
> ```
> 0.4.1 (good):  {"producer": "coreai-core 1.0.0b2", "assetVersion": "2.0", "creationDate": ...}
> 0.4.0 (dead):  {"assetVersion": "2.0"}
> ```
>
> *Audit any tree by that field alone — no dates, no guessing."*

And the caveat that will otherwise give you a false clean bill of health:

> **Community-documented, verbatim:** *"`.aimodelc` bundles **always** carry a `producer` (the
> `coreai-build-<ver>` string), so for those use the **source** `.aimodel`'s producer, not the
> compiled one."*

That caveat is the whole game if you ship compiled assets. Your `.aimodelc` will look fine —
`coreai-build` stamps its own producer on everything it emits, including things it compiled from a
broken source. **The compiled artifact's producer field tells you which compiler ran, not which
converter produced the IR it consumed.**

> 🟡 **RECONSTRUCTED — the `metadata.json` schema for an `.aimodel`.** The three keys quoted above
> (`producer`, `assetVersion`, `creationDate`) come from the community forensics document, which is
> reporting what it observed on disk. `coreai-core` is a binary wheel and its writer is not public,
> so we cannot verify the full key set or their exact spellings against source. What *is* verified
> is that `AIProgram.save_asset(path)` writes a directory containing `main.mlirb`, `main.hash` and
> `metadata.json` — that structure is attested by multiple independent community readers.
>
> ⚠️ **Do not confuse this file with the *bundle* `metadata.json`.** `apple/coreai-models` writes a
> *different* `metadata.json`, one level up, describing a whole bundle (tokenizer, asset roles,
> compression preset). Its schema is fully verified and appears in §8. A bundle directory therefore
> contains **two** files called `metadata.json` at different depths, with different schemas, and
> only the inner one has `producer`. This is a genuine trap for an audit script.

The audit, as a shell one-liner you can run right now:

```bash
# Every .aimodel in the tree, and whether its metadata.json declares a producer.
# Run this BEFORE you repack anything (see §3.4).
find . -type d -name '*.aimodel' -print0 \
| while IFS= read -r -d '' asset; do
    meta="$asset/metadata.json"
    if [ ! -f "$meta" ]; then
      printf 'NO-METADATA  %s\n' "$asset"
    elif grep -q '"producer"' "$meta"; then
      printf 'OK           %s  %s\n' \
        "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("producer"))' "$meta")" \
        "$asset"
    else
      printf 'SUSPECT      (no producer field)  %s\n' "$asset"
    fi
  done
```

A slightly more careful Python version, which also walks *inside* bundle directories, distinguishes
the two `metadata.json` schemas, and refuses to be fooled by a compiled asset:

```python
#!/usr/bin/env python3
"""Audit a tree of Core AI assets for the coreai-torch 0.4.0 producer fingerprint.

Usage: python3 audit_producers.py <root> [<root> ...]

Exit status is 1 if any SUSPECT asset was found, so you can wire this into CI.

Caveats encoded here (see guide 17.6 §3.5):
  * `.aimodel` and `.aimodelc` are DIRECTORIES.
  * A bundle directory has its own metadata.json with a different schema; only the
    per-asset one carries `producer`.
  * `.aimodelc` always carries a producer, so its producer proves nothing about the
    source IR. We report it but never treat it as evidence of health.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SUSPECT = "SUSPECT"
OK = "OK"
UNKNOWN = "UNKNOWN"


def read_producer(asset_dir: Path) -> str | None:
    """Return the `producer` string from an asset's own metadata.json, or None."""
    meta = asset_dir / "metadata.json"
    if not meta.is_file():
        return None
    try:
        blob = json.loads(meta.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    # A *bundle* metadata.json has "metadata_version"/"assets"; it is not an asset
    # manifest and never carries a producer. Do not let it masquerade as one.
    if "metadata_version" in blob and "assets" in blob:
        return None
    producer = blob.get("producer")
    return producer if isinstance(producer, str) else None


def classify(asset_dir: Path) -> tuple[str, str]:
    producer = read_producer(asset_dir)
    if asset_dir.suffix == ".aimodelc":
        # Compiled assets ALWAYS carry a producer (the coreai-build-<ver> string),
        # so this tells you which compiler ran, not which converter made the IR.
        return UNKNOWN, producer or "(none)"
    if producer is None:
        return SUSPECT, "(no producer field — pre-0.4.1 converter)"
    return OK, producer


def main(roots: list[str]) -> int:
    found_suspect = False
    for root in roots:
        for asset in sorted(Path(root).rglob("*")):
            if not asset.is_dir():
                continue
            if asset.suffix not in {".aimodel", ".aimodelc"}:
                continue
            verdict, detail = classify(asset)
            print(f"{verdict:<8} {detail:<34} {asset}")
            found_suspect |= verdict == SUSPECT
    if found_suspect:
        print(
            "\nSUSPECT assets were produced by a converter older than coreai-torch 0.4.1 "
            "and will fail to load on iOS/macOS 27 beta 2 and later. See guide 17.6 §3.6.",
            file=sys.stderr,
        )
    return 1 if found_suspect else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:] or ["."]))
```

Two notes on using it:

- **`UNKNOWN` for `.aimodelc` is deliberate and correct.** If your tree only contains compiled
  assets, this script cannot answer the question, and it says so rather than lying. Go find the
  source `.aimodel` that produced them — which is one more argument for §10's archive.
- **Run it against your CDN listing, not just your build tree.** Published assets are the ones that
  matter. In the community incident, the recovery loop's step 4 was literally *"Verify the uploaded
  `producer` is `coreai-core 1.0.0b2`"* — after upload, on the served copy, because the served copy
  is what users get.

### 3.6 The fix, and the chicken-and-egg inside it

Apple's *first* guidance was re-convert from PyTorch with 0.4.1+. That works, and if you have the
original checkpoints and the original recipes it is the cleanest answer. It is also expensive: for a
large model it is a download, an export, and a re-verification, per model.

Three days after the incident, an Apple maintainer posted a cheaper repair on issue #44:

> **Apple maintainer (@cymbalrush) on `apple/coreai-torch` #44, verbatim:**
> *"Thank you for reporting the issue. Could you try using `strip_debug_info` to remove debugging
> metadata? This should prevent the compiler failure. After stripping the debug information, make
> sure to save the updated asset."*

with this snippet:

```python
from coreai_torch.debugging.debug_info import strip_debug_info
from coreai.authoring import AIModelAsset
from pathlib import Path

asset = AIModelAsset.load(Path("model.aimodel"))
coreai_program = asset.program

strip_debug_info(coreai_program)
coreai_program.save_asset(Path("model_stripped.aimodel"))
```

The insight behind it, from the community write-up: *"the broken assets are healthy except the debug
locations, and those can simply be stripped."*

And the result, which is the number that makes this repair worth doing:

> **Community-measured, verbatim:** *"Verified here on **40 zoo bundles: weights byte-identical,
> minutes per model, stripped assets load clean on beta 3.**"*

**Weights byte-identical.** That is what lets you skip re-running a full quality gate on the output —
you are not re-quantising, you are not re-tracing, you are rewriting location metadata. (You should
still run a *load and generate* check; see §3.7.)

#### What `strip_debug_info` actually does

This is one of the few places in this stack where you can read the repair.

> ✅ **VERIFIED** — `apple/coreai-torch` at `0.4.1`,
> `coreai_torch/debugging/debug_info.py:539`. The signature is:
>
> ```python
> def strip_debug_info(program: AIProgram) -> None:
>     """Strip debugging information from all operations in the program.
>
>     This is useful for reducing asset size when full debug traces are
>     no longer needed.
>
>     Args:
>         program: The AIProgram to strip debug info from. Modified in place.
>     """
> ```
>
> The body walks the MLIR module and replaces every location: it builds one shared
> `Location.file(filename="", line=0, col=0, …)`, sets the module operation's location, then walks
> all nested operations assigning **fresh sequential `coreai` operation IDs** (`operation_id = 0`,
> incrementing), and finally updates every block argument's location to match its operation's.
>
> So the repair is not "delete the locations" — it is "replace stack-trace locations with
> ID-only locations", which is exactly the `Mode.RELEASE` shape (§3.9).

> ⚠️ **A trap in the published snippet — `strip_debug_info` returns `None`.**
> The signature is `-> None` and the docstring says *"Modified in place."* The maintainer's snippet
> on issue #44 is written as a bare statement, which is correct — but the community write-up of the
> thread notes that a reader could reasonably transcribe it as an assignment. If you write:
>
> ```python
> coreai_program = strip_debug_info(coreai_program)   # ← WRONG: rebinds to None
> coreai_program.save_asset(out)                      # AttributeError: 'NoneType' …
> ```
>
> you get an `AttributeError` one line later. That is at least loud rather than silent, but it will
> cost you ten minutes if you do not know the return type. **Call it as a statement:**
>
> ```python
> strip_debug_info(coreai_program)                    # ✅ in place
> coreai_program.save_asset(out)
> ```
>
> Our research corpus previously listed this return value as unverified; it is now verified from the
> shipping source cited above.

#### ⚠️ The chicken-and-egg

Here is the part that turns a five-line fix into an afternoon, and it is the most instructive detail
in the whole incident.

> ⚠️ **On a beta-2-or-later machine, the repair snippet cannot even load the asset.**
> Community-documented, verbatim: *"on a beta 2+ machine the snippet above cannot even load the
> asset (**the authoring bytecode reader in `coreai-core` 1.0.0b2 wheels runs the same versioned-IR
> conversion and aborts**)."*

So `AIModelAsset.load(path)` — the *first line* of the fix — hits the same
`expected AICode versioned location` abort that you are trying to repair.

And now the correction that makes sense of the whole thing. Recall from §3.4 that pinning
`coreai-core` back to `1.0.0b1` "does not help, the gate is OS-side". The community document
**corrects its own earlier finding**, and the correction is precise:

> **Community-documented self-correction, verbatim:** *"The earlier 'pinning `coreai-core` back to
> `1.0.0b1` does not help, the gate is OS-side' finding in this doc was about the **RUNTIME load**
> path; for the **AUTHORING parse** the gate is in the wheel, not the OS."*

**There are two gates and they look like one.**

| | Path | Where the version gate lives | Can you pin around it? |
|---|---|---|---|
| **Runtime load** | `AIModel.load` / `AIModel(contentsOf:)` / `coreai-build compile` | **The OS** (from 27 beta 2) | **No.** The wheel is not in the loop |
| **Authoring parse** | `AIModelAsset.load(...)`, `AIProgram._load_bytecode(...)` | **The wheel** (`coreai-core`'s bundled MLIR) | **Yes.** A `1.0.0b1` wheel parses the old fused locations fine |

That asymmetry is what makes the recovery possible at all. You cannot make a 27-beta-2 device load a
0.4.0 asset. You *can* make a `1.0.0b1` Python environment **read** one — and reading it is all the
repair needs.

The consequence for your machine setup is concrete and slightly annoying:

- You need a venv with **`coreai-core 1.0.0b1`** (and the `coreai-torch 0.4.0` that pairs with it)
  to *parse* the broken asset.
- You need a venv with **`coreai-core 1.0.0b2`** (and `coreai-torch 0.4.1`) to *re-stamp* it, so the
  output carries `producer: coreai-core 1.0.0b2` and passes your own audit (§3.5).
- `strip_debug_info` **does not exist in 0.4.0**, so the b1 venv has to run a *vendored* copy of the
  0.4.1 function. The community write-up notes this needs *"two helper signatures adapting"* — the
  0.4.1 implementation calls internal helpers that the 0.4.0 module tree does not expose under the
  same names.

### 3.7 The full recovery recipe

Two paths. Take path A if you can; path B is for assets you cannot rebuild.

#### Path A — re-convert from source (Apple's original guidance)

Use this when you still have the checkpoint and the recorded export command. It is more work per
model and it re-establishes a clean provenance chain, which is worth something.

The environment the community recovery used, verbatim from the forensics document:

> **Community-documented environment, verbatim:**
> *"`coreai-torch` **0.4.1+**, `coreai-core` **1.0.0b2**, `coreai-opt` **0.2.1**, on the pinned
> `torch==2.9.0` (do NOT let `uv` bump torch to 2.11 — it breaks torchvision with a circular import
> and every export dies at load). Xcode 27 **Beta 3** (`27A5218g`) for AOT — `xcrun coreai-build` →
> `3600.75.3`."*

> ⚠️ **`coreai-torch` allows a torch version it has not validated, and only warns.**
> ✅ **VERIFIED** — `coreai_torch/__init__.py:32-39` in the shipping repo:
>
> ```python
> _TORCH_MAX_VERSION = "2.13.0"
>
> if _Version(_torch_version) > _Version(_TORCH_MAX_VERSION):
>     _warnings.warn(
>         f"coreai-torch has only been validated with torch<={_TORCH_MAX_VERSION}; "
>         f"found torch {_torch_version}. Some functionality may not work as expected.",
>         stacklevel=2,
>     )
> ```
>
> The runtime dependency is declared as `torch>=2.8.0` with **no upper bound**
> (`pyproject.toml`), while the `test` extra pins `torch==2.13.0`. So a fresh resolve can hand you a
> torch the converter has never been tested against, and all you get is a `UserWarning` that your
> log filter probably swallows. **Pin torch explicitly in your export environment.** The community
> recovery pinned `2.9.0`; the repo's own test matrix uses `2.13.0`. Either is defensible; drifting
> is not.

The recovery loop, per model, community-documented verbatim and lightly annotated:

```
1. Export with 0.4.1 using the model's recorded ship command
   (models/<model>/recipe.toml, or the model card).
                                     ← this is why §10 exists: you need the recorded command
2. Gate: coreai_gate.py <bundle> <hf-id> → PASS
                                     ← a behavioural check, not a hash check
3. Upload. Big files (10–40 GB) need HF_HUB_DISABLE_PROGRESS_BARS=1, retries, and
   background — a flaky link kills one-shot uploads mid-file.
4. Verify the uploaded `producer` is `coreai-core 1.0.0b2`.
                                     ← audit the SERVED copy, not the local one
5. For catalog-served models, re-pin catalog.json `revision` — the catalog is fetched
   remotely and revision-pinned, so upload alone does not reach users; the re-pin
   commit does.
6. Free disk: delete the local export and the source weights once upload is verified.
```

Step 5 deserves a highlight, because it generalises well beyond this incident:

> ⚠️ **Publishing a fixed artifact does not ship it.** Community-documented, verbatim: *"the catalog
> is fetched remotely and **revision-pinned**, so **upload alone does not reach users**; the re-pin
> commit does."*
>
> If your app resolves models through a manifest that pins a content revision — and it should, see
> [Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) —
> then fixing the artifact is step *n−1*. Bumping the pin is step *n*. During an incident, under
> pressure, this is exactly the step that gets forgotten, and the symptom is "we fixed it and users
> still report the bug."

**On step 2 — why a hash comparison would not have worked.** The same community repository
documents, separately, that Core AI conversion is **not byte-deterministic**: `main.mlirb` differs by
a handful of bytes run-to-run, and a published 1.19 GB bundle differed by 492 bytes between two
conversions of the same input. Community-measured; attribute as such. The operational consequence is
important and counter-intuitive:

> **You cannot verify a re-conversion by comparing hashes with the old artifact.** Verification has
> to be *behavioural* — load the bundle, generate with a deterministic prompt, and compare tokens
> against a reference. The community gate does exactly this: greedy decode, token-for-token, against
> a reference implementation, with a PASS defined as an exact match *or* a first divergence only
> where the top-2 logit margin is under 0.1 (a genuine numerical tie).
>
> A hash **is** still worth recording (§10) — not to prove two builds are equivalent, but to identify
> *which* bytes a given user has.

#### Path B — repair in place with `strip_debug_info`

Use this when re-conversion is impossible or uneconomic: upstream weights are gone, the recipe is
lost, the model is 40 GB, or you have forty of them.

The three-step recipe, community-documented verbatim, with the two-venv structure from §3.6:

> 1. *"Isolated venv with **`coreai-torch 0.4.0` + `coreai-core 1.0.0b1`** — the b1 wheel's bundled
>    MLIR parses the old fused locations fine."*
> 2. *"`AIProgram._load_bytecode(bundle/main.mlirb)` → **vendored 0.4.1 `strip_debug_info`** (0.4.0
>    lacks it; two helper signatures need adapting) → `save_asset`."*
> 3. *"Re-load + re-save with the b2 wheel (now parses fine) to get a proper
>    `producer: coreai-core 1.0.0b2` fingerprint, then probe + publish."*

As a driver you can adapt. **This is a reconstruction of a described procedure, not a transcription
of a published script** — the community driver scripts (`strip_b1.py` / `strip_sweep.py`) are not in
our corpus. Every API call in it is individually attested; the assembly is ours.

```python
#!/usr/bin/env python3
"""Stage 1 of the 0.4.0 asset repair. RUN THIS IN THE b1 VENV.

Environment: coreai-torch 0.4.0 + coreai-core 1.0.0b1.
The b1 wheel's bundled MLIR still parses the pre-0.4.1 nested `fused` locations,
which is the ONLY reason this stage can read the asset at all (guide 17.6 §3.6).

Usage: python3 strip_stage1.py <in.aimodel> <out.aimodel>
"""

from __future__ import annotations

import sys
from pathlib import Path

from coreai.authoring import AIProgram

# `strip_debug_info` does not exist in coreai-torch 0.4.0. Vendor the 0.4.1
# implementation next to this script (see coreai_torch/debugging/debug_info.py:539)
# and adapt its two internal helper imports to what 0.4.0 exposes.
from vendored_strip_debug_info import strip_debug_info  # noqa: F401  (local vendored copy)


def main(src: Path, dst: Path) -> int:
    bytecode = src / "main.mlirb"
    if not bytecode.is_file():
        print(f"not an .aimodel directory (no main.mlirb): {src}", file=sys.stderr)
        return 2

    # Read the IR directly. AIModelAsset.load() would work on b1 too, but going
    # through the bytecode keeps this stage independent of the asset manifest,
    # which is exactly the part we are about to rewrite.
    program = AIProgram._load_bytecode(bytecode)

    # In place. Returns None. See §3.6.
    strip_debug_info(program)

    program.save_asset(dst)
    print(f"stage 1 ok: {src} -> {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1]), Path(sys.argv[2])))
```

```python
#!/usr/bin/env python3
"""Stage 2 of the 0.4.0 asset repair. RUN THIS IN THE b2 VENV.

Environment: coreai-torch 0.4.1 + coreai-core 1.0.0b2.
Re-reads the stage-1 output (which now parses fine, because the locations are
ID-only) and re-saves it so the asset carries a current producer stamp — which is
what makes the §3.5 audit report OK afterwards.

Usage: python3 strip_stage2.py <stage1.aimodel> <final.aimodel>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from coreai.authoring import AIModelAsset


def main(src: Path, dst: Path) -> int:
    asset = AIModelAsset.load(src)
    asset.program.save_asset(dst)

    meta = json.loads((dst / "metadata.json").read_text())
    producer = meta.get("producer")
    if not producer:
        print(
            f"stage 2 produced an asset with NO producer field: {dst}\n"
            f"the b2 wheel is not what you think it is — check `pip show coreai-core`",
            file=sys.stderr,
        )
        return 1

    print(f"stage 2 ok: {dst}  producer={producer!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(Path(sys.argv[1]), Path(sys.argv[2])))
```

> 🟡 **RECONSTRUCTED — `AIProgram._load_bytecode` and `AIModelAsset.load`.** Both are named in the
> community forensics and in the Apple maintainer's snippet respectively, and both are used as shown.
> Neither appears in Apple's published documentation: `coreai-core` is a binary wheel and Apple's
> documented Python surface does not include the authoring API. The **leading underscore on
> `_load_bytecode` marks it private** — `coreai-torch`'s own documentation carries a warning that
> underscore-prefixed `coreai-core` API *"may move or change without notice across `coreai-core`
> releases"* (✅ verified, `docs/guides/custom-op-lowering.ipynb`). Use it for a one-off recovery,
> not in a pipeline you maintain.

**Then verify.** Do not skip this because "the weights are byte-identical". They are — but a repair
that silently produced an empty program would also produce byte-identical weights, because there
would be no weights to differ. Load the repaired asset and generate something:

```bash
# Cheapest real check: does it load and does it speak?
# (llm-runner ships in apple/coreai-models' Swift package.)
swift run -c release llm-runner --model out/MyModel-repaired --prompt "The capital of France is"
```

Use a **deterministic** prompt. The community gate document is explicit about why:

> **Community-documented, verbatim:** *"Use a **deterministic** prompt ('The capital of France is');
> open-ended prompts hit ties everywhere and aren't gate material."*

### 3.8 What cannot be recovered

Two categories, both worth knowing before you plan a recovery.

**1. Compiled `.aimodelc` assets cannot be stripped.**

> **Community-documented, verbatim:** *"`.aimodelc` (compiled) artifacts **cannot** be stripped —
> those need re-export + AOT recompile."*

Which makes sense: `strip_debug_info` operates on an `AIProgram` — the authoring-level IR — and a
compiled asset is past that stage. If you ship `.aimodelc`, your recovery is necessarily
source-`.aimodel` → repair or re-convert → recompile.

And there is an *independent* reason your compiled assets may need a recompile anyway:

> **Community-documented, verbatim:** *"Beta 2 or earlier `.aimodelc` also need a beta-3 recompile
> per Apple **181264112**, but that is a **separate** issue from the 0.4.0 conversion break — **do
> not conflate them**."*
>
> This matters during triage. If you have both problems you will fix one, re-test, still see
> failures, and conclude the fix did not work. **They are two problems.** Fix the source-asset
> producer first (§3.5–3.7), then recompile every `.aimodelc` on a current toolchain.

**2. Models whose upstream weights have disappeared.**

The community recovery has one permanent casualty, and it is worth stating because it is the failure
mode nobody plans for:

> **Community-documented, verbatim:** one model *"was retired instead of recovered, because
> **Microsoft removed its upstream weights on 2026-06-30**, so it cannot be rebuilt."*

A dated, concrete instance of an upstream checkpoint vanishing and permanently un-reproducing a
downstream artifact. If your build depends on `from_pretrained(<some org>/<some model>)` at export
time, **you do not control your inputs.** §10's checklist includes archiving the source checkpoint
hash for exactly this reason — and if the licence permits, archiving the checkpoint itself.

### 3.9 Preventing a recurrence: `Mode.RELEASE`

The whole incident is downstream of a default. `TorchConverter` defaults to `Mode.DEBUG`, which
embeds full torch stack traces in every asset you convert.

> ✅ **VERIFIED** — `coreai_torch/converter.py`, the constructor docstring, verbatim:
> *"`mode`: Controls the level of debug information embedded in the converted asset. Use
> `TorchConverter.Mode.RELEASE` for lightweight operation-ID-only tracking, or
> `TorchConverter.Mode.DEBUG` (default) for full torch stack traces. Call
> `coreai_torch.debugging.debug_info.strip_debug_info` to remove debug metadata from an
> already-converted program."*
>
> Note also: **`mode` is keyword-only** (`def __init__(self, *, mode=Mode.DEBUG)`), and it is
> **undocumented in the repo's own `docs/api/TorchConverter.md`**, which shows a bare
> `TorchConverter()`. So the flag that would have prevented this incident is present in the source,
> mentioned in a docstring, and absent from the API reference.

For anything you intend to ship:

```python
from coreai_torch import TorchConverter

# Shipping conversion: operation IDs only, no torch stack traces in the asset.
converter = TorchConverter(mode=TorchConverter.Mode.RELEASE)   # keyword-only
```

and for a debugging conversion of the same model, keep the default — that is what makes the Core AI
Debugger able to point at your Python source. The two are not mutually exclusive; convert twice.

> ⚠️ **`Mode.RELEASE` is a prophylactic, not a fix.** It would have avoided this specific incident,
> because the rejected construct was the stack-trace location form. It does not make your assets
> version-proof in general — the versioned-IR format itself can change again, and there is no
> compatibility promise anywhere that says otherwise. Treat `RELEASE` as "ship less metadata,
> present less surface", not as "immune".

A reasonable default policy for a team, stated as three rules:

1. **Ship `RELEASE`-mode assets.** Debug-mode assets are for your laptop.
2. **Record the converter version in your provenance file** (§10) so that when a producer-side
   compatibility break happens, the audit is a `jq` query rather than an archaeology project.
3. **Have a "load it" step in CI, not an "inspect it" step** (§3.3).

---

## 4. Incident 2 — the macOS 26 → 27 export-lowering regression

> **Attribution.** Everything in this section is **community-measured** by a single engineer, on one
> M4 Max and one iPhone 17 Pro, on beta software, and published in a public repository. The primary
> forensics document (`methodology/coreai-export-lowering.md` in the `apple-silicon-llm-bench`
> repository) is **not in our corpus**; what we have are the author's own summaries of it in two
> repositories we did read, plus the A/B tables. Apple has made **no statement** about this. The
> author himself calls it *"plausibly a 27-beta regression in quantized-Linear legalization. Worth
> an Apple feedback with this document attached."* Treat magnitudes as indicative and the mechanism
> as well-argued rather than proven.

If §3 was a bad week, this is the one that can cost you a quarter, because there is no error, no
warning, no log line, and no moment at which anybody is forced to look.

### 4.1 The A/B

The author's own summary, verbatim, and it is worth reading slowly because every clause is a control:

> **Community-measured, verbatim:**
> *"**`coreai.llm.export qwen3-0.6b` produced a 1,116 tok/s artifact when this repo's Mac numbers
> were first taken, and a ~500 tok/s artifact two days later — same command, same registry preset,
> same source checkout, same wheel versions, same machine. The only environment change in between
> was the macOS 26 → 27 beta upgrade. Benchmark the artifact you ship, pin the artifact, and don't
> assume a re-export reproduces it.**"*

Count the controls in that sentence: same command, same preset, same source checkout, same wheel
versions, same machine. The only variable is the host OS.

The A/B table, all three rows measured on the **same day** with the **same `llm-benchmark` binary**
at `-p 128 -g 256 -n 3`:

| Artifact | Exported | Host OS at export | Decode tok/s | Prefill tok/s |
|---|---|---|---:|---:|
| `qwen3_0_6b_dynamic` (original) | 2026-06-09 | **macOS 26** | **1,116** | **17,350** |
| `qwen3_0_6b_4bit_dynamic` (re-export) | 2026-06-11 | **macOS 27 beta** | 500 | 6,667 |
| re-export from pristine upstream `main` @ `0c1055f` | 2026-06-11 | **macOS 27 beta** | 504 | 6,676 |

> **Community-measured**, M4 Max, macOS 26 vs macOS 27 beta, `llm-benchmark` at 128-token prompt /
> 256-token generation, 3 trials. The third row is the control that rules out "his checkout drifted":
> a clean upstream checkout at a named commit reproduces the *slow* artifact to within 1%.

And it reproduces on device, which is the part that makes it a shipping concern rather than a
laptop curiosity. Both artifacts AOT-compiled with `--architecture h18p`, GPU, on the same
**iPhone 17 Pro**, same 512-prompt/1024-generation protocol:

| Artifact | Prompt tok/s | Decode tok/s (run 1 / run 2) | Load cold / warm | Footprint |
|---|---:|---|---|---:|
| macOS-**27β** export | 1,519 | 57.2 / 52.5 | 1.14 s / 0.07 s | 0.47 GB |
| macOS-**26** export | **5,807** | **115.1** / 90.4 | 0.90 s / 0.066 s | **0.22 GB** |

> **Community-measured**, iPhone 17 Pro / iOS 27 beta. The author's summary of this row, verbatim:
> *"**~2× decode, 3.8× prefill, half the memory, from the export environment alone.**"*

So the headline is not one number, it is three:

- **~2.2× decode** on Mac, **~2× decode** on iPhone
- **~2.6× prefill** on Mac, **~3.8× prefill** on iPhone
- **~2× memory footprint** on iPhone (0.47 GB vs 0.22 GB)

and the artifact **file sizes are nearly identical** — 327 MB versus 320 MB, both squarely in the
4-bit storage class. Nothing about looking at the artifact tells you which one you have.

> ⚠️ **The size-dependence is what makes this hard to catch.** Community-measured, verbatim:
> *"The effect is **size-dependent**: at 8B both artifact generations measure ~94 tok/s
> (bandwidth-bound); at 0.6B the lowering dominates (2.2×). **Small-model numbers are the
> canary.**"*
>
> Read that as a testing instruction. If your benchmark suite only exercises your largest model —
> which is the natural choice, because it is the one users notice — **you will not see this
> regression at all**, because at 8B the model is bandwidth-bound and the compute path barely
> matters. Keep a small model in the suite specifically as a canary for lowering changes.

### 4.2 The op-level forensics

The author did not stop at the numbers. He compared the two artifacts' program text and found the
difference, using nothing more exotic than `strings`.

> **Community-measured, verbatim:**
> - **Fast artifact:** *"plain `Linear$N` composites, **zero** quantization ops in the program text,
>   yet 327 MB (4-bit-sized) → 4-bit weights consumed natively by the runtime's Linear kernels
>   (quantized-matmul path)."*
> - **Slow artifact:** *"`ParametrizedLinear$N` composites + **141× `constexpr_blockwise_shift_scale`
>   ops** → explicit dequantize-then-matmul."*
>
> And the one-line conclusion: *"Same 4-bit storage class (327 vs 320 MB); the **compute path**
> differs 2.2×."*

This is a clean, legible mechanism, and it is the kind of thing you can check yourself in ten
seconds (§4.6). Two program shapes for the same weights:

```
FAST (macOS 26 export)                     SLOW (macOS 27β export)
──────────────────────                     ───────────────────────
Linear$0                                   ParametrizedLinear$0
Linear$1                                     └─ constexpr_blockwise_shift_scale   ← dequantise
Linear$2                                     └─ matmul (dense fp16)
  …                                        ParametrizedLinear$1
(no quantization ops in the                  └─ constexpr_blockwise_shift_scale
 program text at all — the                   └─ matmul
 runtime's Linear kernel                       …
 consumes 4-bit weights                    (141 × constexpr_blockwise_shift_scale
 natively)                                  across the program)
```

`constexpr_blockwise_shift_scale` is a real, documented Core AI op, which is what makes the
fingerprint reliable:

> ✅ **VERIFIED** — `apple/coreai-torch` maps the torch-side custom op
> `coreai::constexpr_blockwise_shift_scale(input, scale, zero_point?, minval?, input_dtype?,
> output_dtype?)` to the Core AI op `coreai.blockwise_shift_scale`
> (`coreai_torch/_custom_to_core.py`'s `_custom_to_core_resolver`, and the op table in
> `docs/api/`). `apple/coreai-optimization` documents the same op as the scale-application half of
> its quantised-LUT lowerings. So the op is *supposed* to exist — its presence is not a bug. What
> changed is whether the compiler **folds it into the Linear composite** or leaves it standing.

And on where in the pipeline the fold happens, the author is careful and explicit about what he
does and does not know:

> **Community-measured, verbatim:** *"`quantize_pytorch_model` → `coreai-opt` PT2E `Quantizer`… it
> **ALWAYS** emits the parametrized/dequant form. The fast artifact's plain-`Linear$N`-no-dequant
> form must therefore be produced **LATER**, by the compiler folding dequant into the Linear
> composites during `prog.optimize()` (**`coreai-pre-compilation-rewrite`**) / serialization."*

That is a deduction, not a direct observation of the pass — but it is a sound one, because it is
grounded in the fact that the *quantiser's* output is the same in both cases. The divergence
happens downstream of the quantiser, in optimisation/serialisation.

### 4.3 The mechanism: one wheel, two native stacks

Here is the architectural fact that explains how the *host OS* can possibly influence a Python
package's output.

> **Community-measured, verbatim:** *"**The `coreai-core` wheel ships TWO complete native stacks**
> and picks one at import time (`coreai/runtime/__init__.py`): **macOS < 27 → the wheel-bundled
> local stack (`_coreai_runtime.so`); macOS ≥ 27 + wheel install → the OS framework
> (`_coreai_runtime_os.so`)**. Env overrides exist: **`USE_LOCAL_COREAI` / `USE_OS_COREAI`.**
> **The compiler bindings (`_coreaiIR`) ride the same switch.**"*

Take a moment with that last sentence. It is the load-bearing one.

If only the *runtime* rode the switch, this would be an unremarkable design: the wheel uses the OS's
inference engine when there is one, and falls back to a bundled copy when there is not. Sensible.
But **the compiler bindings ride the same switch**, which means:

```
macOS 26 host                              macOS 27 host
─────────────                              ─────────────
import coreai                              import coreai
   └─ _coreai_runtime.so   (in wheel)         └─ _coreai_runtime_os.so  (OS framework)
   └─ _coreaiIR            (wheel's)          └─ _coreaiIR              (OS's)
        │                                          │
        ▼                                          ▼
   prog.optimize() runs the WHEEL'S           prog.optimize() runs the OS'S
   compiler passes                            compiler passes
        │                                          │
        ▼                                          ▼
   fold dequant into Linear                   emit explicit dequant ops
```

**Your `pip freeze` output no longer describes your compiler.** Two machines with byte-identical
`uv.lock` files, byte-identical `Package.resolved` equivalents, byte-identical everything a
dependency manager can see, will run *different compilers* if they run different macOS versions.

The wheel versions pinned in the investigation, so you can see how tightly controlled it was:
**`coreai-core 1.0.0b1` / `coreai-torch 0.4.0` / `torch 2.9.0`.**

> ⚠️ **This also means the `coreai-core` version pin in your `pyproject.toml` is doing less than you
> think.** ✅ **VERIFIED** — `apple/coreai-torch`'s `pyproject.toml` declares `coreai-core==1.0.0b2`,
> an *exact* pin, which is unusually strict for a Python dependency and clearly deliberate. It pins
> the Python package. It does not, and cannot, pin the OS framework that package will dispatch to on
> a macOS 27 host.

### 4.4 The decisive negative result

The obvious next question is: fine, so force the local stack. The author asked it and answered it.

> **Community-measured, verbatim — the decisive negative result:**
> *"re-exporting on macOS 27β with **`USE_LOCAL_COREAI=1`** — i.e. **the byte-identical frozen wheel
> compiler that produced the fast artifact on macOS 26** — **STILL yields the dequant-style
> artifact**… Same pass code, different OS underneath, different lowering ⇒ **the fold decision
> consults the running OS (capability/target queries under the pass), not just the stack's own
> code.**"*

This is a genuinely good experiment and it is worth appreciating why. It rules out the boring
explanation. If the difference were "the OS ships a newer compiler with a regression", then forcing
the *old* compiler would restore the *old* behaviour. It does not. The old compiler, running on the
new OS, makes the new decision.

Which means the fold decision is not a property of the pass code. It is a property of the pass code
*plus the platform it queries* — target capabilities, delegate availability, something in that
family. And **you cannot pin your way out of a query against the running system.**

The practical consequence, stated as a rule:

> **There is no environment variable, no wheel pin, no lockfile and no container that makes a
> macOS 27 host produce the macOS 26 artifact.** The only known way to produce the macOS 26 artifact
> is to run the export on macOS 26.

The community repository states the same conclusion from the artifact side, in its published model
catalogue:

> **Community-documented, verbatim** (`official/README.md`, "Why artifacts and not just recipes?"):
> *"The same export command can produce a 2.2× slower artifact across an OS upgrade (macOS 26 → 27β
> changed the quantization lowering…). An `.aimodel` is a build artifact: these are the exact,
> hash-stamped bundles behind the published numbers. **The Qwen3-0.6B repo includes the macOS-26-era
> artifact that current toolchains can no longer reproduce.**"*

"Can no longer reproduce" is doing a lot of work in that sentence. That artifact is now, in the most
literal sense, **irreplaceable** — the machine that could make another one has been upgraded.

### 4.5 ⚠️ The lesson: the export host's OS version is an input to the model's performance

> ⚠️ ⚠️ **THE LESSON OF THIS GUIDE**
>
> ### The export host's OS version is an input to the model's performance.
>
> Not to whether it builds. Not to whether it loads. Not to whether it produces correct output — the
> slow artifact is *numerically fine*. To **how fast it runs and how much memory it uses on your
> user's phone.**
>
> Every build system you have ever used treats the host OS as an environmental detail — something you
> upgrade when IT tells you to, something you note in a Dockerfile and forget. In this stack it is a
> **compiler input**, on the same footing as your quantisation preset and your context length. It
> belongs in your build manifest, in your artifact provenance record, and in the metadata line under
> every benchmark number you publish.
>
> The three practices that fall out of it:
>
> 1. **Pin your export machine's OS.** Treat an OS upgrade on a build box the way you would treat a
>    compiler upgrade: a scheduled, deliberate change, with a before/after benchmark on the same
>    device, and a rollback plan. Do not let it happen because someone clicked "Update Now".
> 2. **Benchmark the artifact you will actually ship.** Not the recipe. Not "a Qwen3-0.6B 4-bit
>    export". *That file.* On the target device. If you re-export, re-benchmark — a re-export is a
>    new artifact, not a copy of the old one.
> 3. **Keep the artifact.** Archive the bytes, not just the command. If the command stops being able
>    to reproduce them — and here it did — the bytes are the only copy that exists.
>
> Community-measured; the mechanism is the author's deduction and Apple has not commented. But the
> *practice* the finding implies is correct regardless of whether this specific regression is still
> live, because a stack that can do this once can do it again.

The author's own list of consequences, verbatim, is a tighter statement of the same thing:

> **Community-measured, verbatim:**
> 1. *"**An `.aimodel` is a build artifact, not a pure function of the recipe.** Treat it like a
>    compiled binary: version-stamp it, keep it, benchmark exactly what ships."*
> 2. *"Numbers carry artifact date + OS in an `ENV.md`."*
> 3. *"The effect is size-dependent: at 8B both artifact generations measure ~94 tok/s
>    (bandwidth-bound); at 0.6B the lowering dominates (2.2×). **Small-model numbers are the
>    canary.**"*
> 4. *"If you have a macOS-26-era artifact, **keep it** — as of the 27 beta we know no recipe flag
>    that re-produces the native-quantized lowering."*

### 4.6 The detection recipe

You can tell which lowering you have in about ten seconds, without a device and without a benchmark.
The op names live in the program text.

```bash
# Which lowering did this artifact get?
# FAST  = native quantized-Linear  → few/no constexpr_blockwise_shift_scale, plain Linear$N
# SLOW  = explicit dequant chain   → many constexpr_blockwise_shift_scale, ParametrizedLinear$N

ASSET=exports/qwen3_0_6b_dynamic.aimodel

echo "constexpr_blockwise_shift_scale: $(strings "$ASSET/main.mlirb" | grep -c constexpr_blockwise_shift_scale)"
echo "ParametrizedLinear:              $(strings "$ASSET/main.mlirb" | grep -c 'ParametrizedLinear')"
echo "plain Linear:                    $(strings "$ASSET/main.mlirb" | grep -c 'Linear\$')"
```

Interpreting it, using the community A/B as the calibration:

| Signal | Fast artifact (macOS 26) | Slow artifact (macOS 27β) |
|---|---|---|
| `constexpr_blockwise_shift_scale` count | **0** | **141** |
| Composite names | `Linear$N` | `ParametrizedLinear$N` |
| Artifact size | 327 MB | 320 MB |
| Compute path | quantised matmul, native | dequantise → dense matmul |

> **Community-measured**, Qwen3-0.6B 4-bit dynamic export. The counts are that model's; yours will
> differ with layer count. What generalises is the **shape**: near-zero versus one-per-linear-layer,
> and `Linear$N` versus `ParametrizedLinear$N`.

As a script you can run over a whole tree and wire into CI as a regression detector:

```bash
#!/usr/bin/env bash
# lowering-check.sh — classify Core AI assets by quantisation lowering.
#
# Emits one line per asset. A NON-ZERO dequant-op count on a 4-bit asset means you
# got the explicit dequantize-then-matmul lowering, which community measurement puts
# at ~2.2x slower and ~2x the memory for small models. See guide 17.6 §4.
#
# Usage: ./lowering-check.sh <root>
set -euo pipefail

root="${1:-.}"

printf '%-8s %-8s %-10s %s\n' 'DEQUANT' 'PARAM' 'SIZE' 'ASSET'
find "$root" -type d -name '*.aimodel' -print0 \
| while IFS= read -r -d '' asset; do
    ir=""
    for candidate in "$asset"/main.mlirb "$asset"/main-*.mlirb; do
      [ -f "$candidate" ] && ir="$candidate" && break
    done
    if [ -z "$ir" ]; then
      printf '%-8s %-8s %-10s %s\n' '-' '-' '-' "$asset  (no IR bytecode found)"
      continue
    fi

    dequant=$(strings "$ir" | grep -c 'constexpr_blockwise_shift_scale' || true)
    param=$(strings "$ir"   | grep -c 'ParametrizedLinear'              || true)
    size=$(du -sh "$asset" | cut -f1)

    printf '%-8s %-8s %-10s %s\n' "$dequant" "$param" "$size" "$asset"
  done
```

Wire the output into a comparison against a recorded baseline (§10) rather than against a threshold.
"Zero dequant ops" is not universally the right answer — a model with no quantisation at all has zero
too, and some architectures legitimately use the op. **The signal is a change**, not an absolute.

> 🔴 **GAP — `strings` is a heuristic, and there is no supported way to dump Core AI IR.**
> `main.mlirb` is MLIR *bytecode*. `strings` finds the op names because they are stored as literals,
> but it cannot tell you where they are, whether they are reachable, or what the program actually
> looks like. There is no public `coreai-build dump-ir` and `xcrun coreai-build inspect` prints
> function signatures and weight dtypes, not the op graph.
> **What would resolve it:** a documented IR-printing path, or a stable Python API for walking
> `AIProgram._mlir_module` (currently private, and explicitly warned as unstable).
> **Safe default meanwhile:** use the counts as a *fingerprint for change detection*, never as a
> correctness assertion. Record them alongside a real benchmark number, and treat a change in either
> as a signal to investigate.

### 4.7 The operational rule

Two rules, and a third that is really a consequence.

**Rule 1 — pin your export machine.**

Nominate one machine (or one image) as the export host, record its OS build in your provenance file
(§10), and change it deliberately. In practice, for a team, that means:

```yaml
# build/export-host.yaml — checked in, reviewed like any other build config
export_host:
  os: "macOS 26.4"              # NOT "latest". Pinned. Changing this is a reviewed change.
  os_build: "25E5xxx"           # exact build, because point releases matter (see §5)
  xcode: "27.0 beta 3 (27A5218g)"
  coreai_build: "3600.75.3"     # xcrun coreai-build --version
  python: "3.11"
  wheels:
    coreai-torch: "0.4.1"
    coreai-core:  "1.0.0b2"
    coreai-opt:   "0.2.1"
    torch:        "2.9.0"       # explicit; the package's own bound is >=2.8.0 with NO ceiling
  policy: >
    Upgrading `os` requires: (a) a re-export of the canary model, (b) an on-device
    A/B against the previous artifact, (c) a recorded decision. See guide 17.6 §4.
```

> ⚠️ **The tension you are buying into.** Pinning an export host to an *older* OS conflicts with
> other things you need — §3.7's recovery required Xcode 27 beta 3 for AOT, and Apple's guidance
> during the beta 2/3 window was that older `.aimodelc` need recompiling on current tooling. You may
> genuinely need two machines, or one machine and a documented, reversible upgrade procedure. That
> is annoying and it is the honest answer; there is no configuration that makes the tension go away.
> What you must not do is let the choice be made by an automatic update.

**Rule 2 — benchmark the artifact you will ship.**

Not a fresh export of the same recipe. The exact bytes. On the exact device class. With a protocol
you write down, because protocol swings dwarf a lot of real effects:

> **Community-measured, verbatim:** *"Protocols matter: the same artifact measures **115** (512
> prompt / 1024 generation) and **~184** (128 prompt / 128 generation)."* — a **1.6× swing from the
> measurement protocol alone**, on one artifact, on one device.
>
> And on the same page: *"the drop on run 2 is **thermal**, not cache state"*, with a decode number
> falling from 115.1 to 90.4 tok/s between two back-to-back launches.
>
> [Part 15 reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)
> is the guide for doing this properly. The one-line version: a tok/s number without a stated
> protocol, thermal state and device is not a number.

**Rule 3 (consequence) — keep the artifact forever.**

If the export host is an input, and you cannot always reproduce a given host, then the artifact is
your only durable record of a build. Archive it. §10.

### 4.8 🔴 Status unknown

> 🔴 **GAP — we do not know whether this regression is still live.**
>
> **What is unknown:** whether a current (late-July 2026) macOS 27 beta still emits the explicit
> dequantise lowering for the same recipe, or whether the native quantised-`Linear` fold has been
> restored.
>
> **Why we do not know:** the forensics are dated **2026-06-11**. It is **2026-07-29**. Several
> macOS 27 and Xcode 27 betas have shipped in between. **Nobody in our corpus re-ran the
> experiment** — the author moved on to other work, and there is no Apple statement, no Feedback
> number published for it, and no issue in any of the public `apple/coreai-*` repositories that
> matches it (re-checked 2026-07-29 via GitHub issue search for `constexpr_blockwise_shift_scale`
> and the export-lowering symptoms — still none). (Contrast §3, which has two public issues, an
> Apple root cause, and a maintainer's repair.)
>
> **What would resolve it, exactly:** on a machine running a current macOS 27 beta, with
> `coreai-torch 0.4.1` / `coreai-core 1.0.0b2`:
>
> ```bash
> uv run coreai.llm.export qwen3-0.6b --platform macOS --output-name qwen3_0_6b_lowering_probe
> strings exports/qwen3_0_6b_lowering_probe.aimodel/main.mlirb \
>   | grep -c constexpr_blockwise_shift_scale
> ```
>
> A count near **zero** means the fold is back. A count near the **layer count** (141 for this model)
> means it is not. That is a five-minute experiment and it settles the question. Then benchmark both
> artifacts on device to confirm the count actually predicts the speed.
>
> **Safe default until someone runs it:**
> - **Assume it is live.** Pin the export host, benchmark what you ship, keep your artifacts. Those
>   three practices cost you very little if the regression is fixed, and save you a quarter if it is
>   not.
> - **Do not re-export a shipping model "just to refresh it"** without benchmarking the output. This
>   is the specific mistake the incident is made of.
> - **Do not delete a macOS-26-era artifact** on the theory that you can rebuild it. As of the last
>   published measurement, you cannot.
> - **Do not quote either set of numbers as current.** If you cite them, cite them with the date.

---

## 5. Specialization artifacts are tied to the device *and the OS version*

The third artifact class from §2 is the one that lives on your user's device, and it is the one your
migration planning most likely omits entirely — because it is not in your repository, not in your
CI, and not in your app bundle.

### The rule, and its unconditionality

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, listing the three ways a
> cached specialization is lost, verbatim:
> - **OS update** — *"Specialized assets are tied to the OS version. **The system always invalidates
>   assets on OS update, regardless of policy.**"*
> - **Source model change** — *"If the source `.aimodel` file is modified or deleted, cached assets
>   derived from it become invalid."*
> - **Storage pressure** — *"The system can reclaim space by deleting assets marked as purgeable."*

The second and third are controlled by `AIModelCache.Policy.PurgeConditions`
(`.sourceAssetChangedOrDeleted`, `.storagePressure`). **Nothing controls the first.**

> ✅ **VERIFIED** — `AIModelCache.Policy` overview NOTE, verbatim: *"**Regardless of policy, the
> system always purges assets when the OS updates**, as specialized assets are OS-version specific."*
> And on `.persistent`, verbatim: *"This policy ensures the system does not purge specialized assets
> **until the next OS update**."*

So `.persistent` does not mean permanent. It means *"until the next OS update."*

### Why this belongs in a migration guide

Because the 26 → 27 transition is, from the cache's point of view, one enormous invalidation event —
and then every 27.x point release is another one.

Concretely, for an app that shipped on 26.x with Core ML and is adopting Core AI on 27:

- **Every user who updates to 27 pays first-load cost for every model, once.** That is expected.
- **Every user who takes 27.1, 27.2, 27.3 pays it again.** That is the part teams do not plan for,
  because they think of first-load as a first-launch-after-install cost.
- **`.persistent` does not help.** It helps against storage pressure and source-file changes. Not
  against this.
- **Your bookmarks die too** (§6), which is the mechanism by which a well-designed
  delete-the-source-asset optimisation turns into a re-download.

And the cost is not small. Two community-measured points, both on beta software, attributed to the
`coreai-model-zoo` author:

| Asset | Device | Cold (first) load | Warm load |
|---|---|---:|---:|
| Qwen3-4B iOS ANE preset, 3 GB `.aimodelc` | iPhone 17 Pro | **194 s** | 0.46 s |
| GPU monolith, `.aimodelc` vs uncompiled `.aimodel` (post cache-wipe) | Mac | **4.9 s** vs **19.2 s** | 0.0 s both |
| 0.8B GPU model, cold specialization | iPhone | **~4.8 s** | — |
| 2.3 GB model, cold specialization | iPhone | **~29 s** | — |

Note the second row: AOT compilation makes cold load about **4× faster**, and the OS cache serves
`.aimodelc` too, so warm load is effectively free either way. AOT is a genuine mitigation for
re-specialization cost — but it is a reduction, not a removal:

> ✅ **VERIFIED** — Apple, *Managing model specialization and caching*, verbatim: *"The `specialize`
> method **differs from ahead-of-time compilation**. With ahead-of-time compilation, most of the
> heavy computation happens on your Mac at build time, so on-device specialization finishes faster.
> With `specialize`, **the full specialization process runs on the person's device. You are
> controlling *when* specialization happens, not *reducing the work it does*.**"*

### Making the invalidation visible before your user does

`AIModelCache.model(for:options:)` is the primitive for this, and its defining property is that it
**never specializes**:

> ✅ **VERIFIED** — Apple, `AIModelCache.model(for:options:)` discussion, verbatim: *"If this cache
> holds a specialized asset from previously specializing the model at `modelURL` with the specified
> `options`, this method loads and returns the model. **This method never performs specialization.**"*
> Signature: `final func model(for modelURL: URL, options: SpecializationOptions) throws -> AIModel?`
> — `throws` but **not** `async`, because nothing expensive happens.
> Now also ✅ **SDK-verified** verbatim (`notes/sdk-interfaces/CoreAIDelegates-27.0-macos.swiftinterface:35-38`,
> captured 2026-07-29, recaptured 2026-08-20 from the Xcode 27.0 beta) — and note the module: `AIModelCache` is declared in
> **`CoreAIDelegates`**, the SubFramework that `import CoreAI` re-exports, not in the (empty)
> `CoreAICache` module. The `Policy` statics (`.default`, `.persistent`) and both `PurgeConditions`
> (`.storagePressure`, `.sourceAssetChangedOrDeleted`) are in the same interface (`:47-60`), exactly
> as the article describes them.

So a launch-time sweep is cheap, and comparing it against what you saw last launch tells you an
invalidation happened:

```swift prelude:guide-context
import CoreAI
import Foundation
import OSLog

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
@Observable
final class SpecializationWatch {

    private let log = Logger(subsystem: "com.example.app", category: "coreai.cache")
    private let defaults: UserDefaults
    private let installedModels: () -> [URL]

    /// Models that have no cache entry right now and will pay a specialization
    /// cost on their next load.
    private(set) var needingPreparation: [URL] = []

    /// True when models that WERE ready at last launch are not ready now — i.e. an
    /// OS update or a storage purge happened while we were not running.
    private(set) var invalidationDetected = false

    init(defaults: UserDefaults = .standard, installedModels: @escaping () -> [URL]) {
        self.defaults = defaults
        self.installedModels = installedModels
    }

    func refresh() {
        let models = installedModels()

        let notReady = models.filter { url in
            // One source of truth for options — mismatched options mean a cache MISS
            // and a second multi-GB entry. See Part 7 reference 02 §4.
            let options = ModelSpecialization.options(for: url)
            return (try? AIModelCache.default.model(for: url, options: options)) == nil
        }

        let previouslyReady = Set(defaults.stringArray(forKey: Key.readyModels) ?? [])
        let nowReady = Set(models.map(\.lastPathComponent))
            .subtracting(notReady.map(\.lastPathComponent))

        // Something that was ready before is not ready now.
        let lost = previouslyReady.subtracting(nowReady)

        // Corroborate with the OS build, so we can tell "OS update" from "storage purge"
        // in telemetry. These need different messages to the user.
        let previousOSBuild = defaults.string(forKey: Key.osBuild)
        let currentOSBuild = Self.osBuildVersion

        if !lost.isEmpty {
            invalidationDetected = true
            if previousOSBuild != currentOSBuild {
                log.notice("""
                    Cache invalidated by OS update \
                    (\(previousOSBuild ?? "?", privacy: .public) -> \
                    \(currentOSBuild, privacy: .public)): \
                    \(lost.count, privacy: .public) model(s) need re-specialization.
                    """)
            } else {
                log.notice("""
                    Cache entries disappeared with no OS change — storage purge or \
                    source-asset change: \(lost.count, privacy: .public) model(s).
                    """)
            }
        }

        needingPreparation = notReady
        defaults.set(Array(nowReady), forKey: Key.readyModels)
        defaults.set(currentOSBuild, forKey: Key.osBuild)
    }

    /// The OS build string, e.g. "26A5353q". `kern.osversion` is the build, not the
    /// marketing version — which is what you want, because point releases invalidate too.
    static var osBuildVersion: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &value, &size, nil, 0)
        return String(cString: value)
    }

    private enum Key {
        static let readyModels = "coreai.readyModels"
        static let osBuild = "coreai.lastSeenOSBuild"
    }
}
```

> 🟡 **RECONSTRUCTED** — the `AIModelCache.model(for:options:)` call and its semantics are ✅
> verified from Apple's reference page (quoted above) and the declaration is ✅ SDK-verified
> (`CoreAIDelegates-27.0:35-38`), as is the fact that `SpecializationOptions`
> participates in the cache key. `ModelSpecialization.options(for:)` is the single-source-of-truth
> helper pattern from
> [Part 7 reference 02 §4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md);
> it is app code, not API. `sysctlbyname("kern.osversion", …)` is ordinary Darwin, unrelated to
> Core AI. The `@Observable` wrapper is a design choice.

Two design notes on that code, both of which matter more than they look:

- **It distinguishes "OS update" from "storage purge".** These have different user-facing messages.
  An OS update is expected and explicable ("iOS 27.2 updated your device, so we need to re-prepare
  the model — this takes about a minute"). A storage purge means the device is short on space, and
  the honest message is different. Collapsing them loses the ability to say the right thing.
- **It keys on `kern.osversion`, the build string, not the marketing version.** 27.1 and 27.1.1 are
  different builds and Apple's rule is about *OS update*, not about *major version*. Using
  `ProcessInfo.processInfo.operatingSystemVersion` would miss point-release invalidations.

### What to do with the signal

The Apple-prescribed shape for the *first* time is a dedicated first-run experience:

> ✅ **VERIFIED** — WWDC26 session 326, verbatim: *"**I could kick it off at launch or run it in the
> background but that feels wasteful if the user isn't even interested in this feature yet.** **I
> think a better idea is to create a dedicated first-run experience, where I can move this work to
> happen while the user is learning about the feature for the first time. This keeps model loading
> and specialization out of the interactive flow.**"* And from session 324: *"**It is recommended you
> avoid having model specialization occur within user interactive flows.**"*

For the *re*-specialization after an OS update, that advice does not transfer cleanly, because there
is no first-run experience to hide behind — the user already knows about the feature and expects it
to work. The realistic options, in rough order of how well they behave:

| Approach | When it fits | Watch out for |
|---|---|---|
| **Re-specialize proactively on first launch after a detected invalidation**, behind a small non-blocking status | The feature is central; the model is < ~1 GB | Specialization has **no progress reporting** and no documented cancellation contract — an indeterminate spinner is the honest UI |
| **Re-specialize on next feature entry**, with explanatory copy | The feature is occasional | The user hits a delay they did not hit last week; the copy has to explain why |
| **Background it and gate the feature until ready** | Large models, or several | You are guessing when the user will want it |
| **Do nothing; let it happen inline** | Small models only, where cold load is a second or two | At 194 s this is a bug report |

> ⚠️ **There is no progress reporting for specialization.** `AIModel.specialize` and
> `AIModel.init(contentsOf:)` are plain `async throws` calls that return when they are done. No
> `Progress`, no `AsyncSequence` of stages, and no documented cancellation contract. Design the copy
> for an indeterminate wait: *"This happens once after a system update, and can take a few minutes
> for large models"* is honest. A progress bar stuck at 50% for three minutes is not.
>
> 🔴 **GAP — cancellation.** Whether cancelling the enclosing `Task` stops specialization, and what
> state the cache is left in, is undocumented and untested by anyone in our corpus.
> **What would resolve it:** start `specialize` on a large model on a device, cancel after ten
> seconds, then probe `cache.model(for:options:)` and measure the container size.
> **Safe default meanwhile:** treat specialization as uncancellable. Do not attach it to a view's
> `.task { }` on a screen the user can swipe away.

---

## 6. Bookmarks stop resolving — into a silent `else`

Bookmarks are the API that lets you delete the multi-gigabyte source `.aimodel` and keep running off
the cached specialization. They are a genuinely good idea and they are the correct answer to
"I am now holding two copies of a 3 GB model."

They are also the fourth artifact class from §2, and they inherit every invalidation rule from the
third — plus one of their own.

### The workflow, and the API

```swift illustrative
var bookmarkData: Data { get }                                 // on AIModel
init?(resolvingBookmark bookmark: Data) throws                 // on AIModel
static func deleteEntry(referencedBy bookmark: Data) throws    // on AIModelCache
```

> ✅ **VERIFIED** — all three quoted from Apple's Core AI reference pages; all three now also
> ✅ **SDK-verified** verbatim (`CoreAIDelegates-27.0-macos.swiftinterface:14-20, 41` — the
> bookmark pair is a `CoreAIDelegates` extension on the `CoreAIRuntime` `AIModel` class, which is
> why it comes along with plain `import CoreAI`).
> `bookmarkData` discussion, verbatim: *"The data returned can be stored and later resolved to
> re-create a model with `init?(resolvingBookmark:)`. It contains information about the cache and
> entry backing the model."*

The full loop is covered in
[Part 7 reference 02 §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md).
What matters *here*, in a migration context, is the failure shape.

### ⚠️ The silent failure

> ⚠️ **SILENT FAILURE — `AIModel(resolvingBookmark:)` returns `nil` on the OS-update path.**
>
> The initializer is **both failable and throwing**, and the two failure modes are different in a way
> that is easy to get backwards:
>
> | Situation | Result |
> |---|---|
> | Bookmark data is **malformed** — not produced by `AIModel.bookmarkData` | **throws** |
> | Bookmark is **well-formed but stale** — the entry was purged, deleted, or **invalidated by an OS update** | **returns `nil`** |
> | Bookmark resolves | returns the `AIModel`, pinning the entry |
>
> ✅ **VERIFIED** — Apple's return documentation, verbatim: *"If the bookmark data can be resolved,
> the resulting `AIModel` pins and references the cache entry as the model that generated the
> bookmark data. **If it cannot be resolved due to the specialized asset entry no longer being
> present nil is returned.**"* And the discussion: *"Resolving bookmark data involves checking it is
> a valid bookmark, validating the associated cache and cache entry it references exists, and
> returning a `AIModel` constructed with that specialized asset contained within that entry. **If any
> of these steps fail, nil is returned.**"* The NOTE adds: *"**If the bookmark data is malformed**
> due to not being sourced from `AIModel.bookmarkData` **an error is thrown**."*
>
> **The common case — the one that fires for every user after every OS update — is the `nil` case.**
> Not the throw. There is no error object, no diagnostic, no `Error` you can log the domain of. It is
> an `Optional` that came back empty.
>
> Which means it lands in whatever you wrote on the `else` side of an `if let`, six months ago, when
> you were thinking about the happy path. In practice that is very often a `return nil`, a
> `assertionFailure`, or — worst — nothing at all, because the author reasoned "the bookmark is
> always there, we just saved it."

Apple's own sample code for this workflow, quoted verbatim, has the shape and even labels the branch:

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

> ✅ **VERIFIED** — reproduced verbatim from *Managing model specialization and caching*, comments
> included. Note that Apple's comment on the `nil` path says exactly the right thing — *"or was
> invalidated by an OS update"* — and that the code does nothing on that path except fall through.
> Falling through to a re-download is correct behaviour. **Falling through silently is what you have
> to fix.**

### What "fix it" means

Three things, none of them clever:

1. **Do not collapse the two failure modes.** `try? AIModel(resolvingBookmark: data)` turns a
   programmer error (a garbage blob in `UserDefaults`) into the same value as a routine OS update.
   You will want to know which one is happening in the field.
2. **Log the `nil` path.** Not as an error — it is not one — but as a signal, because its *rate*
   tells you how often your users are paying re-specialization, which is a number you should know
   after a major OS release.
3. **Make the fallback a real code path with a real UI**, not a `return nil`. After an OS update, the
   fallback runs for **every** user at once.

```swift compile:27
import CoreAI
import Foundation
import OSLog

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
enum BookmarkResolution {
    /// Resolved. The returned model pins its cache entry while you hold it.
    case resolved(AIModel)
    /// Well-formed bookmark, entry gone. NORMAL after an OS update, a storage purge,
    /// or a source-asset change under the default policy. Not an error.
    case staleNeedsRespecialize
    /// The persisted Data is not a Core AI bookmark. This is a bug in YOUR persistence.
    case malformed(any Error)
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
func resolveModel(bookmark: Data, log: Logger) -> BookmarkResolution {
    do {
        if let model = try AIModel(resolvingBookmark: bookmark) {
            return .resolved(model)
        }
        // ⚠️ THE SILENT PATH. Every user hits this after every OS update.
        // Log it as a signal, not an error — but DO log it, because its rate is
        // how you find out an OS release just cost your users a re-specialization.
        log.notice("Core AI bookmark stale; cache entry gone. Re-specialization required.")
        return .staleNeedsRespecialize
    } catch {
        // Not a Core AI bookmark at all. Wrong UserDefaults key, a migrated blob,
        // Data written by something else. This one IS your bug.
        log.error("Malformed Core AI bookmark: \(error, privacy: .public)")
        return .malformed(error)
    }
}
```

Then the caller has to *do something* with `.staleNeedsRespecialize`, and the type system makes it
awkward to ignore — which is the point of using an enum here rather than an `AIModel?`.

### ⚠️ And the one bookmarks-specific trap

> ⚠️ **A bookmark does not pin anything.**
> ✅ **VERIFIED** — Apple, `AIModel.bookmarkData` NOTE, verbatim: *"Bookmark data is just data. It
> does not pin entries in the cache. **Only a `AIModel` will pin its associated entry in the cache
> while it is held.**"*
>
> So holding a bookmark across a storage-pressure event protects nothing. If you need an entry to
> survive a screen's lifetime, hold the `AIModel` — which is cheap, because Apple also documents:
> *"The model instance is lightweight and doesn't own weights or intermediate buffers. Those
> resources belong to the functions you load from it."*
>
> That asymmetry is useful: **holding an `AIModel` pins the cache entry at almost no memory cost;
> holding an `InferenceFunction` is what costs memory.** Load the model early, defer
> `loadFunction(named:)` until you actually run.

### The migration checklist for bookmarks

If you are moving a 26.x app onto Core AI, or adopting bookmarks for the first time on 27:

- [ ] Every `AIModel(resolvingBookmark:)` call site distinguishes `nil` from `throw`.
- [ ] The `nil` path logs, and the log is something you can query in aggregate.
- [ ] The `nil` path leads to a real re-specialization flow with UI, not to a silent degradation.
- [ ] If you deleted the source `.aimodel`, you specialized with `cachePolicy: .persistent`
      — otherwise `sourceAssetChangedOrDeleted` lets the system purge the artifact you just paid
      for. (✅ Apple states this directly: *"If your app deletes the source model file to save
      storage, use the `.persistent` policy to keep the cached assets available across launches."*)
- [ ] If you deleted the source `.aimodel`, you can still **get it back** — the re-specialization
      path after an OS update needs the source asset again. A bookmark is not a backup.
- [ ] You have tested the stale path. The cheapest way: specialize, save the bookmark, call
      `AIModelCache.default.deleteEntries(for: url)`, then resolve. You should get `nil`.

That last item is the one that actually catches bugs, and it is a five-line test.

---

## 7. `coreai-build compile` exits 0 for architectures a device will reject

Ahead-of-time compilation is the right answer to a lot of the pain in §5 — a community-measured
**4.9 s vs 19.2 s** cold load on the same Mac, post-cache-wipe — and on iOS it is not optional at
all for anything above toy size:

> **Community-measured, verbatim:** *"The exported `.aimodel` is MLIR IR (`main.mlirb`,
> `compilation.targets: []`). **macOS JIT-compiles it at load time; iOS cannot JIT.** Load the raw IR
> on the phone and you get: `Model load failed: NSPOSIXErrorDomain Code=2 "No such file or
> directory"`."*
>
> ⚠️ **That error message is spectacularly misleading.** A missing *compiled target* surfaces as
> **ENOENT**. If you are debugging an iOS load failure and the error says "no such file or
> directory", check that you shipped an `.aimodelc`, before you check your file paths.

So you will be running `coreai-build compile`. Which brings us to the trap.

### The observed CLI

> **Community-documented**, from a `--help` run verified 2026-06-10:
>
> ```
> coreai-build compile <input.aimodel> [--output <dir>]
>     [--platform iOS|macOS|watchOS|visionOS|tvOS ...]
>     [--min-deployment-version 27.0]
>     [--preferred-compute gpu|neural-engine|none]
>     [--architecture <arch> ...]
>     [--expect-frequent-reshapes]
>
> coreai-build inspect  <asset>.aimodel    # signatures, inputs/outputs, states, weight dtypes
> coreai-build package  <asset>            # re-emits asset, bumps producer; does NOT rewrite IR
> ```
>
> Output naming is Apple-documented: ✅ **VERIFIED**, verbatim — *"`coreai-build` outputs **one
> compiled `.aimodelc` file per device architecture**, using the input model's filename as the
> prefix. For example, compiling `MyModel.aimodel` produces files named **`MyModel.<arch>.aimodelc`**,
> where `<arch>` is the device architecture identifier returned by `deviceArchitectureName` at
> runtime."*
>
> ✅ **GAP — RESOLVED 2026-07-31 — the full flag list, captured first-hand.** `xcrun coreai-build
> compile --help` has now been run on this machine and pasted verbatim into
> **`notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`** (`coreai-build 3600.79.1`). The
> community synopsis above is confirmed flag-for-flag — `--architecture` (repeatable) and
> `--expect-frequent-reshapes` are real, `--preferred-compute` takes `{gpu, neural-engine, none}`
> (default `none`), `--platform` defaults to macOS — and the subcommand list is `compile` |
> `package` | **`inspect`** (flags `--io/--metadata/--storage/--compute/--ops/--json`) | a
> previously-unknown **`metadata`** (edits author/license/description/argument descriptions).
>
> ✅ **And the "tool moved under our feet" mystery is solved — 2026-07-31.** The 2026-07-29
> observation was accurate but incomplete: the Xcode 27.0 beta (`27A5228h`) contains **no
> `coreai-build` binary anywhere in the app bundle** — because **`coreai-build` ships in the
> optional Metal Toolchain component** (`xcodebuild -downloadComponent MetalToolchain`), mounted
> under `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/<hash>/Metal.xctoolchain/usr/bin/`.
> What the app bundle ships is **`aimodelc`** at `Contents/Developer/usr/bin/aimodelc`, which
> demands a command type of **`package` or `compile`** and requires `--output`; its embedded
> diagnostic *"note: Please use 'xcrun coreai-build' instead."* defers to the tool in the *other,
> optional component* — not to a tool missing from the product. With the component installed,
> `xcrun --no-cache --find coreai-build` resolves it (plain `xcrun --find` can fail from a stale
> cache). Practical consequences: **CI must run the `-downloadComponent MetalToolchain` step** or
> it reproduces the "absent" state, and §10's provenance record should capture the exact tool path
> and version string, not just "compiled with Xcode 27".

### ⚠️ The silent failure

> ⚠️ **SILENT FAILURE — a green compile does not validate your architecture choice.**
>
> **Community-documented, device-validated 2026-06-10, verbatim:**
> *"**`coreai-build compile` EXITs 0 for ANY requested arch** — a successful compile does NOT
> validate the arch choice; **only a device load does.**"*
>
> The evidence behind that statement is a pair of device tests, and it is worth reading because it
> also destroys the intuition people use to pick an architecture:
>
> - *"**iPhone 17 Pro = `iPhone18,1` → `h18p`.** An `h17p` `.aimodelc` pushed to it fails to load
>   with `invalidCompiledModel`; the same model compiled `--architecture h18p` loads + runs."*
> - *"**M4 Max Mac = `Mac16,x` → `h16c`.** Of all 20 macOS archs, **only `h16c` loads** in the Python
>   runtime on an M4 Max; `h17*` / `h16g` / `h16s` all raise `RuntimeError`."*
>
> And the author's own correction, which is the useful part:
>
> > *"(Earlier notes saying 'h17p for iPhone 17 Pro' were **name-matching, unvalidated** — corrected
> > here.)"*
>
> **The `h`-numbers track the hardware *device identifier* major version, not the marketing name.**
> iPhone 17 Pro is `iPhone18,1`, so it is `h18`-something, not `h17`-something. Every engineer's
> first guess is wrong, the compiler accepts the wrong guess, and the failure appears on a device as
> `invalidCompiledModel` — a runtime error, in a shipped build, on hardware you may not have.

The failure chain, laid out:

```
you guess an arch  →  coreai-build exits 0  →  CI is green  →  you ship it
                                                                    │
                                                                    ▼
                                            user's device: invalidCompiledModel
```

Nothing in that chain fails until the last box, and the last box is somebody else's phone.

### What to do instead

**1. Do not guess. Read `AIModel.deviceArchitectureName` on the target hardware.**

> ✅ **VERIFIED** — `static var deviceArchitectureName: String { get }`. Apple's discussion, verbatim:
> *"When compiling model assets ahead of time with `xcrun coreai-build compile`, the toolchain
> produces artifacts for specific device architectures. **Use this property to discover which
> compiled asset matches the current device.**"*

The two-line diagnostic build that removes all guesswork:

```swift compile:27
import CoreAI

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
func reportDeviceArchitecture() {
    // Run this once on every device class you support, and write the answers down.
    // This is the ONLY authoritative source for the --architecture values you need.
    print("deviceArchitectureName = \(AIModel.deviceArchitectureName)")
}
```

**2. Select the asset at runtime by that name, and fail loudly if nothing matches.**

A shipping community iOS app ranks candidate compiled assets by whether their filename contains
`AIModel.deviceArchitectureName` — the pattern generalises:

```swift compile:27
import CoreAI
import Foundation

@available(iOS 27.0, macOS 27.0, visionOS 27.0, tvOS 27.0, watchOS 27.0, *)
enum CompiledAssetSelection {

    enum Failure: Error, CustomStringConvertible {
        case noMatchingArchitecture(device: String, available: [String])

        var description: String {
            switch self {
            case .noMatchingArchitecture(let device, let available):
                return """
                    No compiled Core AI asset for this device architecture.
                    device: \(device)
                    shipped: \(available.joined(separator: ", "))
                    A `coreai-build compile` that exited 0 does NOT mean the arch was right.
                    """
            }
        }
    }

    /// Pick the `.aimodelc` whose name carries this device's architecture, and throw a
    /// diagnosable error rather than falling back to an arbitrary one.
    static func choose(from candidates: [URL]) throws -> URL {
        let arch = AIModel.deviceArchitectureName

        // Names are `Base.<arch>.aimodelc`, so match on the exact penultimate component,
        // not a substring — arch codes are short and substring matches misfire.
        if let match = candidates.first(where: { url in
            url.deletingPathExtension().pathExtension == arch
        }) {
            return match
        }

        throw Failure.noMatchingArchitecture(
            device: arch,
            available: candidates.map { $0.deletingPathExtension().pathExtension }
        )
    }
}
```

> 🟡 **RECONSTRUCTED** — `AIModel.deviceArchitectureName` and the `Base.<arch>.aimodelc` naming are
> ✅ verified from Apple's documentation (quoted above). Parsing the arch out of the filename by
> taking `deletingPathExtension().pathExtension` is our code and relies on that naming convention
> holding; a community app in our corpus does the equivalent with a `contains` check, which we
> deliberately tightened because arch codes like `h16c` and `h16g` are short enough to collide inside
> longer names.

**3. Do not ship all twenty architectures.**

> **Community-documented, verbatim:** *"**Always pass `--architecture h18p`** — omitting it emits all
> ~20 Mac GPU archs (**34 GB**)."*
>
> And on the shape of the output: a `--platform macOS` compile produced **20** per-arch `.aimodelc`
> (`h13c` … `h17s`); `--platform iOS --preferred-compute neural-engine` produced **8**
> (`h13g h14g h15g h16g h16p h17g h17p h18p`). Community-measured, Xcode `27A5194q`, macOS 27.0
> `26A5353q`, 2026-06-10.
>
> Apple's own guidance points the same way: ✅ **VERIFIED**, from the AOT article — *"It's recommended
> to **host the compiled assets remotely and download the matching variant to the device at
> runtime**, because each device only uses one of them."* That is Background Assets, and it is
> [Part 15 reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md).

**4. Have at least one device load per shipped architecture in your release process.**

This is the only step that actually closes the hole. A green compile proves the compiler did not
crash. It proves nothing else.

### A second, related landmine at the same layer

While you are in `coreai-build`, one more, because it produces a crash rather than an error:

> ⚠️ **`expectFrequentReshapes = true` on a fixed-shape graph SIGSEGVs on device.**
> **Community-documented, device-validated 2026-07-23, verbatim:** *"The hint is not free insurance —
> it is a request for a **reshape-tolerant** specialization. Ask for it at load time on an all-static
> graph and the runtime **stops using the AOT specialization and compiles on device**, which on
> iPhone 17 Pro segfaults inside the MPSGraph AICode compiler."*
>
> ```
> EXC_BAD_ACCESS (SIGSEGV) … MPSGraphAICodeCompilerDelegate getInitializedAICodeBytecodeWithPayloadPrefix:
>   → Compiler_coreAI.compile(moduleBytecode:to:with:) → libODIECompiler … CompileForDelegates
> ```
>
> *"No error string, no partial output — the app just dies at `AIModel(contentsOf:options:)`."*
>
> Two details that make this worse than it sounds: *"Compiling with `--expect-frequent-reshapes` does
> **NOT** make the runtime hint safe — both the plain and the reshape-hinted `.aimodelc` crash when
> the *runtime* asks for the hint. **It is the load-time option that matters.**"* And the fix is
> trivial once you know: on the affected model, `expectFrequentReshapes = false` gave *"all 6 loads
> in 2.6 s, gate PASS"*.
>
> **Rule:** set `expectFrequentReshapes = true` **only** where shapes genuinely change — dynamic query
> length, bucketed prefill, multi-stage pipelines. Static `S=1` decode graphs and fixed-length
> decoders must load **without** it.

### And one that is not about architectures at all

> ⚠️ **`CoreAI.framework` is absent from the iOS Simulator SDK.**
> Reported on `apple/coreai-models` issue #49 (FB23189921), **still open as of 2026-07-29** (3
> comments, no activity since 2026-06-28), verbatim:
> *"`CoreAI.framework` ships only in the device SDK (it's the Neural Engine inference runtime) and is
> **absent from the iOS Simulator SDK**. … every source that `import CoreAI` fails to compile for an
> iOS Simulator destination."*
>
> The Apple maintainer declined the obvious `#if canImport(CoreAI)` fix on the grounds that it *"would
> basically make all operations into no-op."* Downstream, a developer reported working around it by
> *"separat[ing] all CoreAI functionality into a separate target … and weak link"*, which then trips
> a library-evolution warning.
>
> Why this belongs in a migration guide: if your 26.x app's development loop depended on SwiftUI
> Previews or Simulator testing, adopting Core AI **breaks that loop**, and no amount of artifact
> hygiene fixes it. Budget for device-only iteration on any target that imports Core AI, and consider
> isolating Core AI behind a protocol so the rest of your app still previews.

---

## 8. `metadata.json`'s `compression` field records the request, not the result

The last artifact class, and the smallest file in the bundle, and the one that can cost you the most
disk on a user's phone.

### The bundle manifest

`apple/coreai-models` defines a bundle format: a directory containing one or more `.aimodel`
assets, a `tokenizer/` directory, and a `metadata.json` describing the whole thing. The writer is
public Python and can be quoted exactly.

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/bundle.py`, the metadata
> writer in full:
>
> ```python
> metadata: dict[str, Any] = {
>     "metadata_version": METADATA_VERSION,          # "0.2"
>     "kind": "llm",
>     "name": name,
>     "assets": {"main": f"{name}.aimodel"},
>     "language": {
>         "tokenizer": hf_model_id,
>         "vocab_size": getattr(hf_config, "vocab_size", None),
>         "max_context_length": getattr(hf_config, "max_position_embeddings", None),
>         "embedded_tokenizer": True,
>         "function_map": {"main": ["main"]},
>     },
>     "source": {
>         "model_definition": "torch",
>         "hf_model_id": hf_model_id,
>     },
>     "compression": compression if compression != "none" else None,
>     "compilation": {
>         "date": datetime.now().astimezone().isoformat(),
>         "targets": [],
>     },
> }
> ```
>
> and the reader side, ✅ **VERIFIED** from `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift`:
> `BundleKind` is `{ llm, vlm, diffusion, segmenter }`; `ModelBundle` exposes `metadataVersion`,
> `kind`, `name`, `assets: [String: String]`, `verify()` (*"checks every declared asset exists on
> disk"*), and preserves the raw bytes.

Look at the `compression` line. `compression` is a **`str`** parameter — the preset *name* — threaded
down from the export configuration:

> ✅ **VERIFIED** — `python/src/coreai_models/export/pipeline.py:365` passes
> `compression=config.compression` into the bundle writer, where `config.compression` is the preset
> string (defaulting to `DEFAULT_MACOS_COMPRESSION_PRESET`, i.e. `"4bit"` for the macOS LLM path).
> Nothing between the quantiser and the writer observes whether quantisation *happened*.

### ⚠️ The silent failure

> ⚠️ **SILENT FAILURE — quantisation failures are swallowed, and the manifest still claims success.**
>
> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/compiler.py`, the
> post-MLIR quantisation path, quoted verbatim from source:
>
> ```python
> if quant_type == "int4":
>     try:
>         coreai_program = quantize_weights(
>             coreai_program,
>             dtype=DType.INT4,
>             qscheme=QScheme.SYMMETRIC if symmetric else QScheme.ASYMMETRIC,
>             granularity=_GRANULARITY_MAP[granularity],
>             block_size=block_size,
>             weight_num_threshold=32768,
>             in_place=True,
>         )
>         logger.info("Applied INT4 weight quantization")
>     except ImportError:
>         logger.warning("Core AI quantization not available, skipping quantization")
>     except Exception as e:
>         logger.warning(f"Quantization failed: {e}")
> else:
>     logger.warning(f"Unsupported quantization type: {quant_type}")
>
> return coreai_program
> ```
>
> **`except Exception as e: logger.warning(...)` then `return coreai_program`.** The unquantised
> program is returned. The export continues. The bundle is written. And `metadata.json` says
> `"compression": "4bit"` — because that field records **what you asked for**, not what you got.
>
> So a completed, non-erroring, apparently successful export can hand you a **full-precision asset
> labelled 4-bit**. It will load. It will run. It will produce correct output. It will be roughly
> **four times the size** and use roughly four times the memory.
>
> **The only signal is file size.**

This is the diffusion path specifically — `apply_mlir_quantization` is called from the diffusion
compiler, where quantisation happens *after* MLIR lowering rather than pre-export. It is not the LLM
path, which quantises pre-`torch.export` through PT2E. But the *pattern* — a `metadata.json` field
that records intent — is the bundle format's, and it applies to every kind.

> 🔴 **GAP — how far the "records the request" property extends.** We verified the swallow in the
> diffusion/post-MLIR path and verified that `bundle.py` writes the requested preset string
> unconditionally. We did **not** verify that the pre-export PT2E path has an equivalent swallow —
> `export/pipeline.py`'s pre-export quantisation is a different call site with different error
> handling that we did not read line by line.
> **What would resolve it:** reading `coreai_models/export/pipeline.py`'s compression stage and
> `coreai_models/export/compression.py` end to end for bare `except` clauses.
> **Safe default meanwhile:** treat the `compression` field as a **declaration of intent for every
> kind**, and verify by size. That advice is correct even where the code happens to be strict, and it
> costs one assertion.

### The size check, as a gate

Compute what the asset *should* weigh and compare. This is crude and it works.

```python
#!/usr/bin/env python3
"""Verify that a Core AI bundle's actual size is consistent with its declared compression.

`metadata.json`'s `compression` field records the REQUESTED preset. Quantization
failures are swallowed with a logger.warning (guide 17.6 §8), so the field can claim
4-bit for a full-precision asset. Size is the only signal.

Usage: python3 check_compression.py <bundle-dir> --params <parameter-count>
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Bytes per weight, by the storage class a preset name implies. Extend for your presets.
BYTES_PER_PARAM = {
    "4bit": 0.5,
    "4bit_weight_palettized_group32": 0.5,
    "8bit": 1.0,
    "int8": 1.0,
    None: 2.0,          # "none" is written as JSON null; fp16 trace dtype
}

# Scale + zero-point overhead, embeddings kept at higher precision, tokenizer files,
# and the IR itself all inflate the real number. Community exports land comfortably
# inside this band; outside it, something is wrong.
TOLERANCE_LOW, TOLERANCE_HIGH = 0.75, 1.60


def dir_size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle", type=Path)
    ap.add_argument("--params", type=float, required=True,
                    help="parameter count, e.g. 600e6 for a 0.6B model")
    args = ap.parse_args()

    meta_path = args.bundle / "metadata.json"
    meta = json.loads(meta_path.read_text())
    declared = meta.get("compression")

    if declared not in BYTES_PER_PARAM:
        print(f"unknown compression preset {declared!r}; add it to BYTES_PER_PARAM",
              file=sys.stderr)
        return 2

    expected = args.params * BYTES_PER_PARAM[declared]
    actual = dir_size(args.bundle)
    ratio = actual / expected

    print(f"bundle:    {args.bundle}")
    print(f"declared:  compression={declared!r}")
    print(f"expected:  ~{expected / 1e9:.2f} GB  ({BYTES_PER_PARAM[declared]} B/param)")
    print(f"actual:    {actual / 1e9:.2f} GB   (ratio {ratio:.2f}x)")

    if ratio > TOLERANCE_HIGH:
        print(
            f"\nFAIL: bundle is {ratio:.1f}x its declared storage class.\n"
            f"      A swallowed quantization failure produces exactly this shape.\n"
            f"      Re-run the export with logging at WARNING and grep for "
            f"'Quantization failed'.",
            file=sys.stderr,
        )
        return 1
    if ratio < TOLERANCE_LOW:
        print("\nWARN: bundle is smaller than expected — check your parameter count.",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Calibrate the constants against a known-good export of your own before you trust the thresholds.
Community-published reference points, all from `apple/coreai-models`' official recipes measured by
the `coreai-model-zoo` author (community-measured, M4 Max):

| Model | Preset | Bundle size |
|---|---|---:|
| qwen3-0.6b | `4bit` / fp16 / ctx 8192 | 335 MB |
| qwen3-4b | `4bit` / fp16 / ctx 40960 | 2.1 GB |
| qwen3-8b | `4bit` / fp16 / ctx 40960 | 4.3 GB |
| gemma3-4b-it | `4bit` / bf16 / ctx 131072 | 2.1 GB |
| gemma3-12b-it | `4bit` / bf16 / ctx 131072 | 6.2 GB |
| mistral-7b-instruct-v0.3 | `4bit` / fp16 / ctx 8192 | 3.8 GB |
| gpt-oss-20b | `none` (MXFP4 weights pass through) | 13 GB |

Note the last row: `compression: "none"` and yet a 20B model in 13 GB, because the upstream weights
were already MXFP4 and passed through unchanged. **The `compression` field describes what the
pipeline was asked to do, not what precision the weights are in.** That is a second, entirely
legitimate way the field can mislead you — and another reason to gate on size.

### Where to log

If you own the export, do not rely on a downstream size check alone. Fail the export:

```python
import logging

class FailOnQuantizationWarning(logging.Handler):
    """Turn coreai_models' swallowed quantization failure into a build failure.

    `export/compiler.py` catches every Exception from quantize_weights and emits a
    WARNING, then returns the unquantized program. The export then succeeds and the
    bundle's metadata.json still claims the requested compression. See 17.6 §8.
    """

    TRIPWIRES = ("Quantization failed", "skipping quantization", "Unsupported quantization type")

    def emit(self, record: logging.LogRecord) -> None:
        message = record.getMessage()
        if any(t in message for t in self.TRIPWIRES):
            raise RuntimeError(
                f"Quantization did not happen, but the export would have continued and "
                f"metadata.json would still declare the requested preset. Original "
                f"warning: {message}"
            )


logging.getLogger("coreai_models").addHandler(FailOnQuantizationWarning())
```

> 🟡 **RECONSTRUCTED** — the three tripwire strings are ✅ verified verbatim from
> `export/compiler.py` (quoted above). The logger name `"coreai_models"` follows from the module's
> `logger = logging.getLogger(__name__)` and the package layout, but we have not confirmed the
> effective hierarchy at runtime. Attach to the root logger if in doubt, and test that the handler
> fires by deliberately breaking a quantisation config once.

For *why* you would pick one compression scheme over another, and what each actually costs in
quality, see [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md). This section is only about the
manifest lying to you.

---

## 9. Package-level migrations

The other half of "your build artifacts stop working" is the packages you depend on. Three cases,
picked because each teaches a different failure mode: a real major-version break, a dependency
declaration that resolves to nothing, and a one-line rename that the whole ecosystem is chasing.

### 9.1 `mlx-swift-lm` 2.x → 3.x

`ml-explore/mlx-swift-lm` is the Swift package for running LLMs and VLMs with MLX. Its `main` branch
is a new major version, and the README says so in a box you cannot miss.

> ✅ **VERIFIED** — `README.md`, verbatim:
> *"**The `main` branch is a _new_ major version number: 3.x.** In order to decouple from tokenizer
> and downloader packages some breaking changes were introduced."*
> And immediately after: *"We use `swift-format` to keep the code formatting consistent. **CI has
> this pinned to `603.0.0` right now.**"*

#### What actually changed

The decoupling is the whole story. In 2.x, the package depended on the Hugging Face Hub client and
on a tokenizer implementation. In 3.x it does not — those are **protocols you supply**.

> ✅ **VERIFIED** — `Package.swift` declares exactly two dependencies: `ml-explore/mlx-swift`
> (`.upToNextMinor(from: "0.31.4")`) and `swiftlang/swift-syntax` (`"602.0.0" ..< "604.0.0"`).
> **There is no swift-transformers and no swift-huggingface dependency.** The comment on the
> swift-syntax floor is itself worth stealing: *"602.0.0 floor: swift.org publishes signed prebuilt
> swift-syntax artifacts only for >= 602 tags on current toolchains; a 600.x/601.x resolution falls
> back to the full source compile of swift-syntax."*

The two protocols you now have to satisfy, quoted in full because they are small:

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Downloader.swift` and `TokenizerLoader.swift`:
>
> ```swift
> public protocol Downloader: Sendable {
>     func download(
>         id: String,
>         revision: String?,
>         matching patterns: [String],
>         useLatest: Bool,
>         progressHandler: @Sendable @escaping (Progress) -> Void
>     ) async throws -> URL
> }
>
> public protocol TokenizerLoader: Sendable {
>     func load(from directory: URL) async throws -> any Tokenizer
> }
> ```

#### The call-site migration

Straight from the package's own upgrade documentation, which is the authoritative source:

> ✅ **VERIFIED** — `Libraries/MLXLMCommon/Documentation.docc/upgrade.md`, verbatim:
>
> ```swift
> // Before (2.x) – hub defaulted to HubApi()
> let container = try await loadModelContainer(
>     configuration: LLMRegistry.gemma3_1B_qat_4bit
> )
>
> // After (3.x) – Using HuggingFace integration macros
> import MLXHuggingFace
>
> let model = try await #huggingFaceLoadModelContainer(
>     configuration: LLMRegistry.gemma3_1B_qat_4bit
> )
> ```
>
> and, if you want control over the two halves:
>
> ```swift
> let model = try await loadModelContainer(
>     from: #hubDownloader(),
>     using: #huggingFaceTokenizerLoader(),
>     configuration: modelConfiguration
> )
> ```
>
> Loading from a local directory, verbatim:
> ```swift
> // Before (2.x)
> let container = try await loadModelContainer(directory: modelDirectory)
> // After (3.x)
> let container = try await loadModelContainer(from: modelDirectory)
> ```

The full breaking-change list, ✅ verified verbatim from the same document:

| 2.x | 3.x |
|---|---|
| `hub:` parameter (a `HubApi`) | **`from:`** — any `Downloader`, or a `URL` for a local directory |
| `HubApi` | **`HubClient`** |
| `defaultHubApi` global | **removed** — use `HubClient.default` from the `HuggingFace` module |
| `tokenizer.decode(tokens:)` | **`decode(tokenIds:)`** — *"to align with the `transformers` library in Python"* |
| `ModelConfiguration.tokenizerId`, `.overrideTokenizer` | **`tokenizerSource: TokenizerSource?`** — `.id(String)` or `.directory(URL)` |
| `ModelConfiguration.preparePrompt` | **removed** — *"This shouldn't be used anyway, since support for chat templates is available"* |
| `ModelConfiguration.modelDirectory(hub:)` | **removed** |
| `loadTokenizer(configuration:hub:)` | **removed** — `AutoTokenizer.from(directory:)` |
| `replacementTokenizers` / `TokenizerReplacementRegistry` | **removed** — `AutoTokenizer.register(_:for:)` |
| `downloadModel(hub:configuration:progressHandler:)` | `Downloader.download(id:revision:matching:useLatest:progressHandler:)` |
| `loadTokenizerConfig(configuration:hub:)` | `AutoTokenizer.from(directory:)` |
| `ModelFactory._load(hub:configuration:progressHandler:)` | `_load(configuration: ResolvedModelConfiguration)` |
| `ModelFactory._loadContainer` | **removed** (base `loadContainer` builds from `_load`) |
| `MLXEmbedders.ModelConfiguration.nomic_text_v1_5` | `EmbedderRegistry.nomic_text_v1_5` |
| `MLXEmbedders.loadModelContainer(hub:configuration:)` (free function) | `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)` |
| `MLXEmbedders.ModelType` | **removed** |

#### ⚠️ The upgrade doc names two modules that do not exist in the package

> ⚠️ **SILENT FAILURE — the migration document's own "Breaking Changes" section is stale.**
>
> `upgrade.md`'s Breaking Changes section says, verbatim: *"For most users who were using the default
> Hub client, **adding `import MLXLMHuggingFace` or `import MLXEmbeddersHuggingFace`** and using the
> convenience overloads is sufficient."*
>
> ✅ **VERIFIED — neither module exists.** `grep -rn "MLXLMHuggingFace\|MLXEmbeddersHuggingFace"
> --include='*.swift'` over the whole checkout at HEAD `3cbf928` returns **zero** hits, and neither
> name appears in `Package.swift`. The nine products the package actually vends are `MLXLLM`,
> `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`, **`MLXHuggingFace`**, `MLXFoundationModels`,
> `MLXGuidedGeneration`, `BenchmarkHelpers`, `IntegrationTestHelpers`.
>
> The same staleness runs deeper: the package's **shipped agent skill** (`skills/mlx-swift-lm/`) and
> four library `README.md` files import `MLXLMHuggingFace  // from swift-huggingface-mlx` and
> `MLXLMTokenizers  // from swift-tokenizers-mlx`, packages that are referenced nowhere in
> `Package.swift`.
>
> **Why this is a silent failure and not just a doc bug:** the failure it produces is
> `no such module 'MLXLMHuggingFace'`, which reads like *your* project is misconfigured. Engineers
> spend real time re-resolving packages and clearing DerivedData over this. And if you are using a
> coding agent, the shipped skill will *confidently generate the stale imports*, because that is what
> it was written against.
>
> **The two paths that actually work, as of HEAD `3cbf928`:**
> 1. **Hand-rolled conformances** to `Downloader` and `TokenizerLoader` — the protocols are four
>    lines total, quoted above.
> 2. **The `MLXHuggingFace` macros** over `swift-huggingface` + `swift-transformers`:
>    `#hubDownloader()`, `#huggingFaceTokenizerLoader()`, `#huggingFaceLoadModelContainer(…)`,
>    `#huggingFaceLoadModel(…)`, `#huggingFaceLanguageModel(…)`.

The macros expand to code that references symbols **at your call site**, which produces another
confusing error class:

> ⚠️ **Macro expansions need imports you did not write.**
> ✅ **VERIFIED** — `Libraries/MLXHuggingFace/FoundationModelsMacros.swift:17-25` documents that the
> expansions reference `Foundation`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXLMCommon`,
> `HuggingFace` and `Tokenizers`, all of which must be imported **where you invoke the macro**.
> Missing one produces a "cannot find type X in scope" error pointing at *generated* code.
>
> The `#hubDownloader()` expansion, ✅ verified verbatim from
> `HuggingFaceIntegrationMacros.swift:25-64`, shows exactly what it needs:
>
> ```swift
> { (hubApi: HuggingFace.HubClient) -> MLXLMCommon.Downloader in
>     struct HubBridge: MLXLMCommon.Downloader {
>         private let upstream: HuggingFace.HubClient
>         init(_ upstream: HuggingFace.HubClient) { self.upstream = upstream }
>
>         public func download(
>             id: String, revision: String?, matching patterns: [String],
>             useLatest: Bool,
>             progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
>         ) async throws -> URL {
>             guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
>                 throw HuggingFaceDownloaderError.invalidRepositoryID(id)
>             }
>             let revision = revision ?? "main"
>             return try await upstream.downloadSnapshot(
>                 of: repoID, revision: revision, matching: patterns,
>                 progressHandler: { @MainActor progress in progressHandler(progress) })
>         }
>     }
>     return HubBridge(hubApi)
> }(HubClient())
> ```

#### The 27-only surface, and the trait that gates it

If you need to build against both the 26 and 27 SDKs — which is guide
[17.4](04-dual-sdk-builds.md)'s subject — `mlx-swift-lm` shows you the mechanism it uses itself:

> ✅ **VERIFIED** — `Package.swift`, the trait declaration, verbatim comment included:
>
> ```swift
> traits: [
>     // Gates the MLXLanguageModel adapter for Apple's FoundationModels
>     // framework. Default-on. Disabling the trait compiles MLXFoundationModels
>     // to an empty library: the entire `MLXLanguageModel` / `MLXLanguageModel.Executor`
>     // surface requires FoundationModels types that are not available on platforms
>     // older than iOS/macOS/visionOS 27.0 …
>     .trait(name: "FoundationModelsIntegration", description: "…"),
>     .default(enabledTraits: ["FoundationModelsIntegration"]),
> ],
> ```
>
> and the source-level gate, `FoundationModelsMacros.swift:3`:
>
> ```swift
> #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
> ```
>
> **`canImport(FoundationModels, _version: 2)`** is the interesting half — a *module version* check,
> not an OS-availability check, which is what lets one source tree compile against two SDK
> generations. Guide 17.4 covers when this is the right tool and when `@available` is.

And the CI shape, which is the practical proof it works:

> ✅ **VERIFIED** — HEAD commit `3cbf928` is literally
> *"Integration tests: build on both macOS 26 and 27 SDKs (#464)"*, authored 2026-07-24 by an Apple
> engineer. The lint job **builds `swift-format` from source pinned at `603.0.0`**, with this
> rationale verbatim: *"a new swift-format release can change formatting rules and reformat files no
> PR touched, turning the whole-repo `pre-commit run --all` red on every open PR at once."*
>
> That pin is a small, well-reasoned instance of this guide's whole thesis: **an unpinned tool is an
> uncontrolled input to your build.** If you contribute to this package, match the pin locally or
> your diffs will churn.

Recent commits in the same repo also show what beta-era SDK drift costs downstream, which is worth
knowing before you assume a package "just works" on a new beta:

> ✅ **VERIFIED** — from the repo's own commit log: a commit fixing sampling-mode enum cases renamed
> `.top` → `.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`, *"which broke compilation
> against the newer SDK"*; commit `1c86cc1`, which found that the FM-27 beta `.swiftinterface`
> declares `…Action.updateUsage(input:output:metadata: = [:])` while **the shipping dylib exports
> only `updateUsage(input:output:)`**, so the compiled reference alone **SIGSEGVs at load** under
> chained-fixups linking and the call had to be removed entirely; and `9cd1a48`, *"Fix
> FoundationModels API drift and the integration tests that no longer compiled"*.
>
> ⚠️ That middle one is the nastiest artifact-compatibility failure in this entire guide: **the
> `.swiftinterface` and the dylib disagreed.** Your code compiled against a declaration that did not
> exist at runtime, and the failure was a segfault at *load*, before `main`. There is no defensive
> coding against that; there is only "pin your SDK and re-test on every seed."

### 9.2 `foundation-models-utilities`: the dependency line that resolves to nothing

`apple/foundation-models-utilities` is Apple's *"Emerging and experimental patterns for building with
the Foundation Models framework"* — the package that ships `ChatCompletionsLanguageModel` (the
`LanguageModel` conformance that turns `mlx_lm.server`, Ollama, vLLM and LM Studio into Foundation
Models backends), the history-management modifiers, and the `Skills` / `SkillActivation` surface.

Apple links it directly from the Foundation Models documentation:

> ✅ **VERIFIED** — Apple's Foundation Models documentation, verbatim: *"Get the **Foundation Models
> framework utilities** (`https://github.com/apple/foundation-models-utilities`) to access a
> collection of building blocks to help you explore emerging practices in working with large language
> models."*

#### ⚠️ The silent failure

> ⚠️ **SILENT FAILURE — the README's dependency line resolves to nothing.**
>
> The README instructs consumers to write, ✅ verified verbatim from `README.md:30`:
>
> ```swift
> .package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0")
> ```
>
> ✅ **VERIFIED — the only tags that exist are `1.0.0-beta1` and `1.0.0-beta3`**
> (`git ls-remote --tags`; `1.0.0-beta1` → `a047a50`, `1.0.0-beta3` → `376ca60`). There is **no
> `1.0.0`**, and `gh release list` is empty.
>
> **SwiftPM's `from:` requirement excludes prereleases.** A version range starting at `1.0.0` does
> not match `1.0.0-beta3`, because semantic versioning orders prereleases *below* their release. So
> the line Apple's README tells you to write **matches no version at all**.
>
> Why this is silent rather than loud: the *symptom* is a resolution error, which reads like a
> network problem, a private-repo problem, or a stale package cache. Engineers retry, clear
> `~/Library/Caches/org.swift.swiftpm`, delete `Package.resolved`, check their token — and the whole
> time the requirement is simply unsatisfiable. Nothing tells you "there are tags, they are all
> prereleases, and your requirement excludes prereleases."

#### How to actually depend on it

Three options, in descending order of how much we would recommend them:

```swift illustrative
// 1. RECOMMENDED — pin the exact prerelease tag. Reproducible, and it moves only when you move it.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    exact: "1.0.0-beta3"
),

// 2. Pin a revision. Use when you need a commit that is not tagged, or when you want the
//    strongest possible guarantee. There are only two commits in the whole repository,
//    so this is unusually tractable here.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    revision: "376ca60e61985369d5067bd3c575bdb6a13f0e1b"
),

// 3. Track a branch. Convenient during a beta, and a reproducibility hazard: `Package.resolved`
//    records the resolved commit, but a fresh `swift package update` will move you.
.package(
    url: "https://github.com/apple/foundation-models-utilities",
    branch: "main"
),
```

> ✅ **VERIFIED** — repository facts as of the last read: **two commits total** (`a047a50` "Hello
> foundation-models-utilities", 2026-06-07; `376ca60` "Updates to accompany Xcode 27 beta 3",
> 2026-07-10), `main` is the only branch, **zero pull requests in any state**, **issues disabled on
> GitHub** (bug reports are routed to the Apple Developer Forums and Feedback Assistant), Apache-2.0,
> `swift-tools-version: 6.2`, platforms `.macOS("27.0") .iOS("27.0") .visionOS("27.0")
> .watchOS("27.0")`, and **zero external dependencies** (`FoundationModels` is a system framework).

Once you have pinned it, note the platform floor: **27.0 on every platform.** There is no way to
adopt this package in a target that still supports 26.x. If you need one codebase for both, the
package has to sit behind a trait or a `#if canImport` boundary — see guide
[17.4](04-dual-sdk-builds.md).

#### The commit message that is a changelog

There is a second reason to know this repository during a migration, and it has nothing to do with
depending on it: **commit `376ca60`'s message is the best public beta1 → beta3 changelog for the
Foundation Models framework surface itself.**

> ✅ **VERIFIED** — `git log`, commit `376ca60` "Updates to accompany Xcode 27 beta 3", message
> verbatim:
>
> ```
>   - Renamed SamplingMode enum cases — `.top` → `.randomTopK` and
>     `.nucleus` → `.randomProbabilityThreshold`.
>   - Removed `.model(any LanguageModel)` modifier since it's now included in the
>     Foundation Models framework.
>   - `SkillActivations` no longer conforms to `RandomAccessCollection` — replaced with
>     a public `activeSkillNames` property and an `isActive(_:)` method.
>   - Added `urlSessionConfiguration` parameter to `ChatCompletionsLanguageModel.init` —
>     allows tuning timeouts, proxies, and other transport settings; defaults to an
>     ephemeral configuration.
>   - Added instructions parameter to `Skills` — lets callers override the default
>     leading instructions rendered above the skill list.
>   - `Skills` now emits a default leading instruction telling the model to silently
>     activate a matching skill or otherwise respond normally.
>   - `ToggleSkillTool` default description — now instructs the model to activate
>     without asking permission or announcing activation.
>   - Improved skill instructions formatting …
>   - `ChatCompletionsLanguageModel` schema name uses the new `GenerationSchema.name` API.
>   - Fixed `SkillActivations` observation.
> ```

Two of those lines are framework-level renames that will break *your* code too, not just this
package's — `SamplingMode.top` → `.randomTopK` and `.nucleus` → `.randomProbabilityThreshold`. The
same rename shows up independently in `mlx-swift-lm`'s commit history (§9.1), which is how you know
it is the framework moving and not one package's preference.

> ⚠️ **Beta-era package pinning cuts both ways.** Pinning `1.0.0-beta3` protects you from surprise
> API churn, and it also means you are now compiling against a package written for **Xcode 27
> beta 3**. When beta 4 renames something else, a pinned package does not follow. Watch the repo, or
> expect to move the pin. There is a public forum thread reporting `SkillActivation` APIs from this
> package failing to build on Xcode 26 — the mirror-image version of the same problem.

### 9.3 `apple/coreai-models` #123 — the ecosystem chasing the same rename

The smallest item in this section, included because it is a perfect miniature of what guide
[17.3](03-error-taxonomy-migration.md) documents at scale.

> ✅ **VERIFIED** — `apple/coreai-models` HEAD at the time of reading is
> **`5ed9981 "Move away from deprecated FM API (#123)"`**, authored 2026-07-23. The full diff is two
> lines across two files:
>
> ```diff
> --- a/swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift
> +++ b/swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift
> @@ -61,7 +61,7 @@ public struct CoreAILanguageModel: LanguageModel {
>          if isGuidedGenerationSupported { caps.append(.guidedGeneration) }
> -        return LanguageModelCapabilities(capabilities: caps)
> +        return LanguageModelCapabilities(caps)
> ```
> ```diff
> --- a/swift/Sources/CoreAILanguageModels/VLM/CoreAIVisionLanguageModel.swift
> +++ b/swift/Sources/CoreAILanguageModels/VLM/CoreAIVisionLanguageModel.swift
> @@ -29,7 +29,7 @@ public struct CoreAIVisionLanguageModel: LanguageModel {
>       public var capabilities: LanguageModelCapabilities {
> -        LanguageModelCapabilities(capabilities: [.vision])
> +        LanguageModelCapabilities([.vision])
> ```
>
> **Deprecated:** `FoundationModels.LanguageModelCapabilities.init(capabilities:)`.
> **Replacement:** `LanguageModelCapabilities.init(_:)` — unlabelled, taking
> `[LanguageModelCapabilities.Capability]`. Capability cases observed in use across the two files:
> `.toolCalling`, `.reasoning`, `.guidedGeneration`, `.vision`.

What makes this worth a section:

1. **This is Apple's own repository chasing Apple's own rename**, three days after the
   `foundation-models-utilities` beta-3 update in §9.2. If Apple's first-party packages are still
   catching up to the beta-to-beta API surface, your assumption that "a package that builds today
   builds tomorrow" is not safe.
2. **The rename is argument-label-only.** `init(capabilities:)` → `init(_:)`. That is a *deprecation*,
   not a removal, so today you get a warning. When the deprecated overload goes, you get an error —
   in someone else's package, in a build you did not change.
3. **It is invisible in a `Package.resolved` diff.** Bump a dependency and this class of change comes
   along with it, silently, unless you read the commit log.
4. **The same commit window has a sibling** that is *not* a deprecation: commit `102f832` ("Polish a
   few APIs, method names, and remove unnecessarily vending public extension"), same day, renamed
   `CoreAIRunner.init(from bundle:)` → `init(bundle:)`, `PerformanceMetrics.setPromptTokenCount(_:)`
   → `recordPromptTokens(_:)`, `setGeneratedTokenCount(_:)` → `recordGeneratedTokens(_:)`,
   `getGeneratedTokenCount` → a `generatedTokenCount` property, removed `CLILogger.setLevel(to:)` in
   favour of a settable `static var level`, and *un-published* `Duration.inSeconds` / `.inMilliseconds`
   with the rationale *"vending members on a standard-library type we don't own would pollute
   `Duration`'s API surface for every client of this library."* (✅ verified from the repo.)

> ⚠️ **`apple/coreai-models` is not a versioned dependency in the normal sense.** ✅ **VERIFIED** —
> its README states: *"**We are not accepting code contributions at this time** … If you open a pull
> request, it will be closed."* Its own Swift package pins `mlc-ai/xgrammar` on **branch `main`**, not
> a semver range — a reproducibility footgun inside a first-party package. And a maintainer has
> stated in an issue thread that the published `coreai-models` **PyPI wheel "is just a stub"**, so the
> Python half must be used from a source checkout.
>
> Practical consequence for your migration: **pin `apple/coreai-models` by revision**, and read the
> commit log when you move the pin. `from:` on a repository with this much intentional churn is not
> doing what you want.

#### The general rule this section is really about

| What you pinned | What you actually pinned | What still moves |
|---|---|---|
| A package version | That package's source | Its transitive deps on `branch: "main"` |
| A wheel version (`coreai-core==1.0.0b2`) | The Python package | **The OS framework it dispatches to** (§4.3) |
| An Xcode version | The compiler and SDK | Nothing, and this is the strongest pin you have |
| A `Package.resolved` | Resolved commits | Nothing, until someone runs `swift package update` |
| Nothing (you did not pin) | — | Everything, including `swift-format` reformatting your whole repo |

Three of those five rows have a real example in this guide.

---

## 10. The artifact provenance checklist

Everything above is a story about a question somebody had to answer under pressure:

- *"Which of our published models were built with 0.4.0?"* (§3)
- *"Which of our benchmark numbers were taken on macOS-26-era artifacts?"* (§4)
- *"Which architectures did we actually compile for this release?"* (§7)
- *"Is the asset we shipped actually 4-bit?"* (§8)

Each of those is answerable in **minutes** if you recorded the right things at build time, and takes
**days** of archaeology if you did not. During the community 0.4.0 recovery, the audit was
`grep producer` and the answer was immediate — because a `producer` field happened to exist. You
should not depend on happening to be lucky.

This section is the checklist. It is deliberately boring.

### The record

For every artifact you publish — every `.aimodel`, every `.aimodelc`, every bundle — record a
sidecar with **at least** these fields:

```json
{
  "artifact": {
    "name": "qwen3_0_6b_dynamic",
    "kind": "aimodel",
    "path": "exports/qwen3_0_6b_dynamic.aimodel",
    "bytes": 335544320,
    "content_hash": "sha256:9f2c…",
    "built_at": "2026-07-28T09:14:22+09:00"
  },

  "producer": {
    "coreai_torch": "0.4.1",
    "coreai_core": "1.0.0b2",
    "coreai_opt": "0.2.1",
    "torch": "2.9.0",
    "python": "3.11.9",
    "asset_producer_field": "coreai-core 1.0.0b2",
    "converter_mode": "RELEASE"
  },

  "export_host": {
    "os_name": "macOS",
    "os_version": "26.4",
    "os_build": "25E5xxx",
    "hardware": "Mac16,5 (M4 Max)",
    "xcode": "27.0 beta 3 (27A5218g)",
    "coreai_build": "3600.75.3",
    "metal_toolchain": "v27.1.5194.15"
  },

  "recipe": {
    "command": "uv run coreai.llm.export qwen3-0.6b --platform macOS --output-name qwen3_0_6b_dynamic",
    "source_model": "Qwen/Qwen3-0.6B",
    "source_revision": "a1b2c3d4e5f6…",
    "compression_requested": "4bit",
    "context_length": 8192,
    "trace_dtype": "float16"
  },

  "targets": {
    "platform": "macOS",
    "architectures": ["h16c"],
    "preferred_compute": "gpu",
    "expect_frequent_reshapes": false,
    "device_validated": ["Mac16,5"]
  },

  "verification": {
    "lowering_fingerprint": {
      "constexpr_blockwise_shift_scale": 0,
      "parametrized_linear": 0,
      "linear": 28
    },
    "size_vs_declared_ratio": 1.12,
    "behavioural_gate": "PASS (16/16 greedy tokens vs fp16 reference)",
    "benchmark": {
      "device": "Mac16,5 (M4 Max)",
      "os": "macOS 27.0 beta (26A5353q)",
      "protocol": "512 prompt / 1024 generation, 5 trials, release build",
      "decode_tok_s": 484.0,
      "prefill_tok_s": 9396.0,
      "measured_at": "2026-07-28T09:31:05+09:00"
    }
  }
}
```

### Why each field is there

Nothing on that list is decorative. Each one exists because a specific failure in this guide would
have been cheap to diagnose if it had been recorded.

| Field | The question it answers | Section |
|---|---|---|
| `producer.coreai_torch` + `asset_producer_field` | *"Which assets were built by the bad converter?"* | §3.5 |
| `producer.converter_mode` | *"Did we ship debug stack traces?"* | §3.9 |
| **`export_host.os_version` / `os_build`** | ***"Which artifacts got the good lowering?"*** | **§4** |
| `export_host.xcode` / `coreai_build` | *"Do these `.aimodelc` need a toolchain recompile?"* | §3.8, §7 |
| `recipe.command` | *"How do we rebuild this?"* — the recovery loop's step 1 | §3.7 |
| `recipe.source_revision` | *"The upstream repo changed / vanished. What did we actually build from?"* | §3.8 |
| `recipe.compression_requested` | *"What did we ask for?"* — paired with the next row | §8 |
| `verification.size_vs_declared_ratio` | *"…and did we get it?"* | §8 |
| `targets.architectures` + `device_validated` | *"Which of these did a real device actually load?"* | §7 |
| `targets.expect_frequent_reshapes` | *"Why does this one model SIGSEGV on load?"* | §7 |
| `verification.lowering_fingerprint` | *"Did a re-export silently change the compute path?"* | §4.6 |
| `verification.behavioural_gate` | *"Is the repaired asset still correct?"* — hashes cannot answer this | §3.7 |
| `verification.benchmark` | *"Is the thing we shipped as fast as the thing we measured?"* | §4.7 |
| `artifact.content_hash` | *"Which exact bytes does this user have?"* | below |

> ⚠️ **On `content_hash`: record it, but do not expect it to prove equivalence.**
> Community-measured: Core AI conversion is **not byte-deterministic** — `main.mlirb` differs by a
> handful of bytes run-to-run, and a published 1.19 GB bundle differed by **492 bytes** across two
> conversions of the same input. So `hash(rebuild) != hash(original)` tells you nothing.
>
> The hash is for **identity**, not equivalence: *this* file, the one on the CDN, the one in the
> crash report, the one the user has. That is exactly what you need during an incident.
> **Equivalence is established behaviourally** (§3.7).

### Two places to put it

**1. A sidecar file, checked in and published.** `<name>.provenance.json` next to the artifact, and a
copy in your repository. This is the one you actually query during an incident, because `jq` over a
directory of sidecars answers "which artifacts are affected" in one command:

```bash
# "Which published artifacts were exported on macOS 27?"
jq -r 'select(.export_host.os_version | startswith("27"))
       | "\(.artifact.name)\t\(.export_host.os_version)\t\(.artifact.content_hash)"' \
   published/**/*.provenance.json
```

```bash
# "Which artifacts were built by a pre-0.4.1 converter?"
jq -r 'select(.producer.coreai_torch < "0.4.1") | .artifact.path' \
   published/**/*.provenance.json
```

That is the §3 audit, answered from a file instead of from the assets. The reason to have both is
that the sidecar can answer questions the asset cannot — the asset does not know what host OS built
it (§4), and that is the field you will most want.

**2. Inside the asset itself**, so the record survives being copied around detached from your
repository. Core AI supports this directly, and the API is verified:

> ✅ **VERIFIED** — `AIModelAsset` exposes creator-defined metadata with a mutating update:
>
> ```swift
> mutating func updateMetadata(_ updates: (inout AIModelAsset.Metadata) throws -> Void) throws
> ```
>
> *"Pass a closure that takes the existing metadata and updates it. After the closure executes, this
> method writes the new metadata to the model asset on disk."* `Metadata` has `description`, `author`,
> `license`, `creationDate`, and `creatorDefinedMetadata: [String : Metadata.CreatorDefinedValue]`,
> where `CreatorDefinedValue` is an enum with cases `.string`, `.integer`, `.number`, `.bool`,
> `.array`, `.dictionary`. Six typed subscript overloads exist, disambiguated by a defaulted `type:`
> parameter — `String`, `Bool`, `Double`, `Int`, `[CreatorDefinedValue]`,
> `[String: CreatorDefinedValue]`.
>
> Apple's own example, verbatim:
> ```swift
> var asset = try AIModelAsset(contentsOf: input)
> try asset.updateMetadata { metadata in
>   metadata.author = "Alice"
>   metadata.description = "An example model"
>   metadata["iterations"] = 1000 // Custom metadata
> }
> ```

So you can stamp provenance into the asset from a Swift build step:

```swift compile:27
import CoreAI
import Foundation

@available(macOS 27.0, *)
func stampProvenance(
    at assetURL: URL,
    exportHostOSBuild: String,
    coreaiTorchVersion: String,
    recipeCommand: String,
    contentHash: String
) throws {
    var asset = try AIModelAsset(contentsOf: assetURL)
    try asset.updateMetadata { metadata in
        metadata.author = "Example Inc."
        metadata.license = "Apache-2.0"

        // The field this guide exists to make you record. See §4.
        metadata["export_host_os_build"] = exportHostOSBuild

        metadata["coreai_torch_version"] = coreaiTorchVersion
        metadata["recipe_command"] = recipeCommand
        metadata["content_hash"] = contentHash
    }
}
```

> 🟡 **RECONSTRUCTED** — the `AIModelAsset.updateMetadata` API and the `String`-typed subscript are ✅
> verified from Apple's reference pages (quoted above). The *choice* of keys is ours. The Python-side
> equivalent is `AIModelAssetMetadata`, passed as an optional second positional to
> `program.save_asset(path, metadata)` — ✅ verified in use in `apple/coreai-models`
> (`export/metadata.py`'s `build_aimodel_metadata(hf_model_id, component=None) ->
> AIModelAssetMetadata`, which sets `author`, `license`, `model_description` and
> `creation_date = int(time.time())`).
>
> 🔴 **GAP:** whether the **Python** `AIModelAssetMetadata` exposes the creator-defined dictionary
> that the Swift `Metadata` does is unverified — `apple/coreai-models` only ever sets the four
> standard fields, and `coreai-core` is a binary wheel.
> **What would resolve it:** `python -c "import coreai.runtime as r; help(r.AIModelAssetMetadata)"`
> in an environment with the wheel installed.
> **Safe default meanwhile:** write the sidecar JSON from Python (which always works), and stamp
> creator-defined keys from Swift if you need them in-asset.

Worth knowing about Apple's own stamping helper, because its failure mode is the pattern this whole
guide warns about:

> ✅ **VERIFIED** — `apple/coreai-models`, `export/metadata.py`: `build_aimodel_metadata` looks the
> model up in a hardcoded `_METADATA` dict. For an unregistered id it logs an 80-`!` banner warning
> and **returns metadata with only `creation_date` populated** — *"so the export still completes."*
> The asset ships with blank author, licence and description.
>
> A loud warning and a degraded artifact. Better than silence, and still an export that succeeds
> while producing something you did not ask for. If you export models outside Apple's catalogue,
> **you** are responsible for the metadata; nothing will stop you shipping an anonymous asset.

### The three-line version

If you take nothing else from this guide:

1. **Record the export host's OS build** alongside every artifact. It is the single field this stack
   makes load-bearing and no build system records by default.
2. **Archive the artifact bytes**, not just the command that produced them. The command may stop
   being able to reproduce them, and §4 is a dated instance of exactly that.
3. **Benchmark the bytes you ship**, on the device class you ship to, with a written-down protocol —
   and store the number next to the bytes.

---

## 11. Triage: what to check, in what order

You arrived here because something broke, or because you are about to move a project to 27 and want
to know what will. Work down the table.

| Symptom | Probable cause | Go to |
|---|---|---|
| `expected AICode versioned location, got: loc(fused<...>)` | Asset converted with `coreai-torch` 0.4.0 | [§3](#3-incident-1--the-coreai-torch-040-ir-location-break) |
| `Failed to convert to versioned IR` / `LLVM ERROR: cannot unwrap empty odiec_module_t` | Same | [§3](#3-incident-1--the-coreai-torch-040-ir-location-break) |
| `coreai-build inspect` succeeds but `compile` fails | Same — `inspect` is not a health check | [§3.3](#33-️-why-it-is-vicious-inspect-still-works) |
| A model got slower after you re-exported it, and nothing else changed | Export-lowering regression; check the host OS | [§4](#4-incident-2--the-macos-26--27-export-lowering-regression) |
| Memory footprint roughly doubled with no recipe change | Same | [§4.1](#41-the-ab) |
| Small models regressed, large models did not | Same — the effect is size-dependent | [§4.1](#41-the-ab) |
| First load is slow again after an OS update | Cache invalidation; unconditional, by design | [§5](#5-specialization-artifacts-are-tied-to-the-device-and-the-os-version) |
| App silently re-downloads a model it already had | Bookmark resolved to `nil`, `else` branch did the wrong thing | [§6](#6-bookmarks-stop-resolving--into-a-silent-else) |
| `invalidCompiledModel` on device, green build in CI | Wrong `--architecture`; compile exits 0 regardless | [§7](#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject) |
| `NSPOSIXErrorDomain Code=2 "No such file or directory"` loading on iOS | You shipped an uncompiled `.aimodel`; iOS cannot JIT | [§7](#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject) |
| `EXC_BAD_ACCESS` inside `MPSGraphAICodeCompilerDelegate` at load | `expectFrequentReshapes = true` on a fixed-shape graph | [§7](#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject) |
| `no such module 'CoreAI'` building for the Simulator | `CoreAI.framework` is device-SDK-only | [§7](#7-coreai-build-compile-exits-0-for-architectures-a-device-will-reject) |
| Asset is ~4× the size its metadata implies | Swallowed quantisation failure; metadata records the request | [§8](#8-metadatajsons-compression-field-records-the-request-not-the-result) |
| `no such module 'MLXLMHuggingFace'` | That module does not exist; the upgrade doc is stale | [§9.1](#91-mlx-swift-lm-2x--3x) |
| SwiftPM cannot resolve `foundation-models-utilities` | `from: "1.0.0"` excludes the only (prerelease) tags | [§9.2](#92-foundation-models-utilities-the-dependency-line-that-resolves-to-nothing) |
| A dependency stopped compiling after an Xcode beta | FM API drift; see the beta1→beta3 changelog | [§9.2](#92-foundation-models-utilities-the-dependency-line-that-resolves-to-nothing) |
| `LanguageModelCapabilities(capabilities:)` deprecation warning | Argument-label rename to `init(_:)` | [§9.3](#93-applecoreai-models-123--the-ecosystem-chasing-the-same-rename) |
| Whole-repo `swift-format` diff on an unrelated PR | Unpinned `swift-format`; CI pins `603.0.0` | [§9.1](#91-mlx-swift-lm-2x--3x) |

### The pre-flight, for a project you are about to migrate

Run these before you start, in this order. Each is minutes.

```bash
# 1. Which of your assets were built by a pre-0.4.1 converter?  (§3.5)
python3 audit_producers.py ./exports ./published

# 2. Which lowering did they get?  Record the counts as a baseline.  (§4.6)
./lowering-check.sh ./exports

# 3. Is the declared compression consistent with the size?  (§8)
python3 check_compression.py exports/my_model --params 600e6

# 4. What is this device's architecture, really?  (§7)
#    Run a debug build containing:  print(AIModel.deviceArchitectureName)

# 5. What is your export host?  Record it. It is a build input.  (§4.5, §10)
sw_vers ; sysctl -n hw.model ; xcodebuild -version ; xcrun coreai-build --version
python3 -c "import coreai_torch, torch; print(coreai_torch.__version__, torch.__version__, coreai_torch.__file__)"
```

Step 5's last line is the one people skip and the one that catches the shadowing-`egg-info` problem
(§3.4), because it prints where `coreai_torch` was actually imported from.

### What to fix first

If more than one thing applies, this is the order that minimises wasted work:

1. **Producer audit (§3.5) before anything else**, because `coreai-build package` destroys the
   evidence and you may be about to run it.
2. **Record your export host (§10)** before you upgrade anything, because you cannot recover the
   information afterwards.
3. **Baseline your lowering fingerprints and benchmarks (§4.6)** before you re-export anything,
   because a regression is only detectable against a baseline.
4. Then fix things.

---

## 12. Sources and evidence ledger

### Apple documentation (evidence class 3)

| Claim | Source |
|---|---|
| Specialization produces code *"tied to that device's hardware and OS version"* | *Managing model specialization and caching* (`/documentation/coreai/managing-model-specialization-and-caching`) |
| OS update purges the cache *"regardless of policy"* | Same article; repeated on `AIModelCache.Policy` and `Policy.PurgeConditions` |
| `.persistent` holds *"until the next OS update"* | `AIModelCache.Policy` reference |
| `model(for:options:)` *"never performs specialization"* | `AIModelCache.model(for:options:)` reference |
| `specialize` controls *when*, not *how much* | *Managing model specialization and caching* |
| Bookmark: malformed → **throws**, stale → **`nil`** | `AIModel.init(resolvingBookmark:)` reference |
| *"Bookmark data is just data. It does not pin entries in the cache."* | `AIModel.bookmarkData` NOTE |
| `AIModel` is lightweight; functions own the memory | `AIModel` overview NOTE |
| `init(contentsOf:)` accepts `.aimodel` **or** `.aimodelc` | `AIModel.init(contentsOf:options:)` parameter docs |
| `deviceArchitectureName`; `Model.<arch>.aimodelc` naming | `AIModel.deviceArchitectureName` reference; the AOT article |
| *"host the compiled assets remotely and download the matching variant"* | The AOT article |
| `AIModelAsset` inspects without specializing; `isValid(at:)`'s three checks | `AIModelAsset` overview and `isValid(at:)` |
| `updateMetadata(_:)`, `Metadata`, `CreatorDefinedValue`, six typed subscripts | `AIModelAsset.Metadata` reference pages |
| Foundation Models docs link to `foundation-models-utilities` | Apple's Foundation Models documentation |

### Apple source and shipping repositories (evidence class 2)

| Claim | Source |
|---|---|
| `TorchConverter.Mode` = `{DEBUG, RELEASE}`, **DEBUG is the default**, `mode` is keyword-only | `apple/coreai-torch` `coreai_torch/converter.py:140`, `Mode` docstring |
| `include_stack_trace = mode == Mode.DEBUG` | `coreai_torch/converter.py:110-138` |
| `strip_debug_info(program: AIProgram) -> None`, in place; rewrites all locations to ID-only | `coreai_torch/debugging/debug_info.py:539` |
| `coreai_torch.__version__ == "0.4.1"` | `coreai_torch/__version__.py` |
| `coreai-core==1.0.0b2` exact pin; `torch>=2.8.0` with no ceiling; warns above 2.13.0 | `coreai-torch` `pyproject.toml`, `__init__.py:32-39` |
| `constexpr_blockwise_shift_scale` → `coreai.blockwise_shift_scale` | `coreai_torch/_custom_to_core.py` resolver; `apple/coreai-optimization` lowering docs |
| Private `coreai-core` API *"may move or change without notice"* | `coreai-torch` `docs/guides/custom-op-lowering.ipynb` |
| Bundle `metadata.json` schema 0.2, incl. `"compression": compression if … else None` | `apple/coreai-models` `python/src/coreai_models/export/bundle.py` |
| `compression=config.compression` — the request, threaded straight through | `apple/coreai-models` `export/pipeline.py:365` |
| **Quantisation failures swallowed** with `logger.warning` | `apple/coreai-models` `export/compiler.py` (`apply_mlir_quantization`) |
| `build_aimodel_metadata` degrades to `creation_date` only, with a banner warning | `apple/coreai-models` `export/metadata.py` |
| `BundleKind = {llm, vlm, diffusion, segmenter}`; `ModelBundle.verify()` | `apple/coreai-models` `swift/Sources/CoreAIShared/Bundle/ModelBundle.swift` |
| Commit #123 diff: `LanguageModelCapabilities(capabilities:)` → `(_:)` | `apple/coreai-models` `5ed9981`, 2026-07-23 |
| Commit `102f832` API polish (five renames + un-published `Duration` members) | `apple/coreai-models`, same day |
| *"We are not accepting code contributions"*; `xgrammar` on `branch: "main"` | `apple/coreai-models` `README.md`, `Package.swift` |
| `mlx-swift-lm` 3.x upgrade guide, full breaking-change list | `ml-explore/mlx-swift-lm` `Libraries/MLXLMCommon/Documentation.docc/upgrade.md` |
| `Downloader` / `TokenizerLoader` protocol definitions | `Libraries/MLXLMCommon/Downloader.swift`, `TokenizerLoader.swift` |
| Two dependencies only; the swift-syntax 602 floor rationale | `mlx-swift-lm` `Package.swift` |
| `FoundationModelsIntegration` trait; `canImport(FoundationModels, _version: 2)` | `Package.swift`; `FoundationModelsMacros.swift:3` |
| `#hubDownloader()` expansion; required call-site imports | `HuggingFaceIntegrationMacros.swift:25-64`; `FoundationModelsMacros.swift:17-25` |
| **`MLXLMHuggingFace` / `MLXEmbeddersHuggingFace` do not exist** | `grep` over the checkout at HEAD `3cbf928`; `Package.swift` product list |
| swift-format pinned `603.0.0`, with rationale | `README.md`; `.github/workflows/pull_request.yml` |
| Dual-SDK CI; `.swiftinterface`-vs-dylib SIGSEGV (`1c86cc1`); FM drift fixes | `mlx-swift-lm` commit log (`3cbf928`, `1c86cc1`, `9cd1a48`) |
| Only tags are `1.0.0-beta1` / `1.0.0-beta3`; two commits; issues disabled; zero deps; 27.0 floor | `apple/foundation-models-utilities` `git ls-remote --tags`, `git log`, `Package.swift`, `README.md` |
| The beta1 → beta3 framework changelog | `foundation-models-utilities` commit `376ca60` message |

### SDK interfaces and toolchain probes (evidence class 2 — captured/run 2026-07-29, Xcode 27.0 beta `27A5228h`)

| Claim | Source |
|---|---|
| `AIModelCache.model(for:options:)` signature verbatim (`throws -> AIModel?`, not async); `AIModelCache` lives in **`CoreAIDelegates`**; `Policy` / `PurgeConditions` statics (§5) | `notes/sdk-interfaces/CoreAIDelegates-27.0-macos.swiftinterface:29-60` |
| `bookmarkData` / `init?(resolvingBookmark:)` / `deleteEntry(referencedBy:)` verbatim (§6) | Same interface `:14-20, 41` |
| `import CoreAI` is an umbrella: `CoreAI` → `@_exported CoreAIDelegates` → `@_exported` Asset/Common/Compiler/Runtime, all `-public-module-name CoreAI`; `CoreAICache`/`CoreAICommon`/`CoreAICompiler` have empty public surfaces | `CoreAI-27.0-macos.swiftinterface:5`; `CoreAIDelegates-27.0:5-8`; the three stub interfaces |
| No public error type in `CoreAIRuntime`; `CoreAIAsset.AssetError` is the only public Core AI error (relevant to §3/§7 triage — see [17.5 §5.2](05-coreml-to-coreai.md)) | `CoreAIRuntime-27.0-macos.swiftinterface` (grep), `CoreAIAsset-27.0:229-247` |
| `coreai-build` not included in the Xcode 27.0 beta app bundle; with the optional Metal Toolchain component not installed, `xcrun coreai-build` did not resolve. The bundle's `aimodelc` stub was present (`package`\|`compile`, `--output` required), embedding *"Please use 'xcrun coreai-build' instead"* (§7) | Run directly on this machine, 2026-07-29 |
| `coreai-build 3600.79.1` **found in the Metal Toolchain component**; full `--help` for `compile`/`package`/`inspect`/`metadata` captured; `--preferred-compute {gpu, neural-engine, none}`; 24 `--architecture` codes enumerated by validation probing (§7) | `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`, run 2026-07-31 |

| Claim | Source |
|---|---|
| Root cause: 0.4.0 baked stack traces as MLIR `fused` locations; beta-2 compiler rejects; fires on deep hierarchies | `apple/coreai-torch` **#37** + v0.4.1 release notes |
| The `strip_debug_info` repair recipe | `apple/coreai-torch` **#44**, maintainer @cymbalrush |
| Full error text with `call_stack = ["PixelShuffle$1", …]` | `apple/coreai-torch` **#37** reporter |
| *"Beta 3 needs new exports and clean re-compile"* | `apple/coreai-models` **#77**, maintainer @stikves |
| `CoreAI.framework` absent from the iOS Simulator SDK (FB23189921), still open | `apple/coreai-models` **#49** |

### Community sources (evidence class 6 — always attributed as such)

All from the `coreai-model-zoo` / `apple-silicon-llm-bench` public repositories of a single
engineer, measured on **one M4 Max and one iPhone 17 Pro**, on **beta** software.

| Claim | Date | Note |
|---|---|---|
| The 0.4.0 incident: scope, negative list, `producer` fingerprint, environment, recovery loop, two-wheel `strip_debug_info` recipe, 40 bundles byte-identical | 2026-07-18, updated 2026-07-21 | `knowledge/coreai-torch-041-ir-incident.md`, read directly |
| Runtime gate is OS-side; **authoring gate is in the wheel** — an explicit self-correction | 2026-07-21 | Same file |
| `.aimodelc` cannot be stripped; retired model with deleted upstream weights (2026-06-30) | 2026-07-21 | Same file; `README.md` |
| The macOS 26 → 27 export-lowering A/B (1,116 → 500 tok/s), op-level forensics, two-native-stacks mechanism, `USE_LOCAL_COREAI=1` negative result | **2026-06-11** | Primary doc `methodology/coreai-export-lowering.md` **not in our corpus**; quoted via the author's own summaries in `knowledge/apple-models-bench.md` and `official/README.md`, both read directly |
| iPhone A/B: 115.1 vs 57.2 tok/s decode, 5,807 vs 1,519 prefill, 0.22 vs 0.47 GB | 2026-06 | `knowledge/apple-models-bench.md`, read directly |
| Size-dependence (8B unaffected, 0.6B 2.2×); "small-model numbers are the canary" | 2026-06 | Same |
| *"the macOS-26-era artifact that current toolchains can no longer reproduce"* | — | `official/README.md`, read directly |
| `coreai-build compile` **exits 0 for any `--architecture`**; `h18p` vs `h17p` device validation; M4 Max = `h16c` only | 2026-06-10 | `knowledge/aot-and-specialization.md`, read directly |
| `expectFrequentReshapes = true` SIGSEGVs a fixed-shape graph at load | 2026-07-23 | Same |
| 20 macOS archs / 8 iOS archs; omitting `--architecture` emits 34 GB | 2026-06-10 | Same |
| AOT cold load 4.9 s vs 19.2 s; 194 s cold load on a 3 GB `.aimodelc`; 0.8B ≈ 4.8 s, 2.3 GB ≈ 29 s | 2026-06/07 | Same; `knowledge/apple-models-bench.md` |
| iOS cannot JIT; `NSPOSIXErrorDomain Code=2` for a missing compiled target | 2026-06 | `methodology/coreai-ios.md` via our notes |
| `coreai-build` CLI `--help` surface | verified 2026-06-10 | `knowledge/aot-and-specialization.md` |
| Conversion is **not byte-deterministic** (492 B of 1.19 GB) | — | Zoo `CONTRIBUTING.md` / `PORTING.md` via our notes |
| Protocol swing 115 vs 184 tok/s on one artifact; run-2 drop is thermal | 2026-06 | `knowledge/apple-models-bench.md` |
| Official-recipe bundle sizes table (335 MB … 13 GB) | 2026-06/07 | Same |
| Shadowing `coreai_torch.egg-info` silently downgrades exports | 2026-07-18 | `knowledge/coreai-torch-041-ir-incident.md` |

### 🔴 Declared gaps in this guide

1. **The exact IR-format change** between beta 1 and beta 2 (§3.2). Resolved by an Apple statement or
   the `coreai-core` MLIR dialect definition.
2. **The `.aimodel` `metadata.json` full schema** (§3.5) — three keys are attested by observation;
   the writer is a binary wheel.
3. **Whether the macOS 26 → 27 export-lowering regression is still live** (§4.8). Resolved by a
   five-minute re-export plus `strings | grep -c`. **This is the highest-value open question in the
   guide** — it changes the advice in three sections.
4. **No supported way to dump Core AI IR** (§4.6); `strings` is a heuristic fingerprint.
5. **Whether specialization is cancellable** (§5). Resolved by a device test.
6. **Whether the pre-export PT2E quantisation path swallows failures** the way the post-MLIR path does
   (§8). Resolved by reading `export/pipeline.py` and `export/compression.py` end to end.
7. ~~**`coreai-build compile --help`'s full flag list** (§7)~~ **CLOSED 2026-07-31** — a real
   `--help` is pasted in `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`. The 2026-07-29
   confusion (`27A5228h`'s app bundle does not contain `coreai-build`, and the optional component was not
   installed; `aimodelc` embeds "Please use 'xcrun coreai-build' instead") resolved: the tool lives
   in the **optional Metal Toolchain component**,
   not the app bundle. Both spellings coexist by design — `coreai-build` is the developer CLI,
   `aimodelc` the Xcode-internal stub.
8. **Whether Python's `AIModelAssetMetadata` exposes creator-defined keys** (§10). Resolved by
   `help()` in an environment with the wheel.
9. **`AIProgram._load_bytecode` / `AIModelAsset.load`** are private/undocumented (§3.7) and may move.

---

*Guide 17.6 · Part 17 — Migration from pre-iOS 27. Continue with*
[*17.1 — What changed between iOS 26 and iOS 27*](01-what-changed-checklist.md) *for the source-level
diff, or* [*Part 15*](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/README.md) *for the distribution and benchmarking
practices this guide keeps pointing at.*
