# Memory, jetsam, thermals, energy, and measuring honestly

**Part 15 · Shipping and operating on device · Reference 02**

**Version floor: iOS 27 / iPadOS 27 / macOS 27 / visionOS 27 and Xcode 27** for everything that
touches Core AI (`AIModel`, `SpecializationOptions`, `AIModelCache`, the `CoreAILanguageModels`
engine stack) and for the 2026 Foundation Models surface. But most of this guide is *older* than
that and that is the point: the jetsam model, `os_proc_available_memory()`, `phys_footprint`,
`ProcessInfo.ThermalState` and the `com.apple.developer.kernel.increased-memory-limit` entitlement
all long predate 2026, and the shipping app this guide leans on hardest targets
**`IPHONEOS_DEPLOYMENT_TARGET = 18`** with `MACOSX_DEPLOYMENT_TARGET = 26.0`
(✅ **VERIFIED**, `notes/repos/noema-ios.md` §2, read from `Noema.xcodeproj/project.pbxproj`). Every
API below is marked with the earliest OS the corpus actually attests for it. Where a technique is
version-independent, it says so.

Three things in this guide are **specifically 27-era**: Core AI's on-device specialization tax and
its jetsam consequences, the `EngineOptions` / `KVCacheStrategy` memory dials in
`apple/coreai-models` (**iOS 27.0 / macOS 27.0 / tvOS 27.0 / watchOS 27.0 / visionOS 27.0+**), and
the fact that `SystemLanguageModel` runs **out of process**, which changes what your memory numbers
even mean.

---

## What this covers

This is the guide about the gap between a demo that works on your desk and an app that survives a
week on someone else's phone. It has the highest crash-avoidance value in the series, and almost
none of it is about writing better inference code. It is about four things that the frameworks do
not tell you and that no error message will announce:

- **§1–§3 — Memory and jetsam.** iOS does not hand you an allocation failure. It kills you. This
  section covers the two OS signals that tell you how much room you actually have, why the
  arithmetic "model is 4 GB, phone has 8 GB, therefore fine" is wrong in at least five separate
  ways, and two documented real failures where a model *loaded successfully* and then died.
- **§4–§6 — Living inside the budget.** What a shipping multi-backend app actually does about
  memory pressure: a hysteretic governor, a background unload policy, verified unloads. Then the
  MLX-specific dials — the buffer cache limit, the memory limit, wired-memory tickets — and the
  unified-memory hazard nobody warns you about: **another framework's allocator can starve yours**.
- **§7–§8 — Thermals and energy.** The section most benchmarks omit entirely. A19 prefill
  throughput moves ~40% purely on DVFS clock ramp, with thermals eliminated as the cause. And
  throughput and energy produce *different rankings* from the same device on the same day, so
  "fastest" and "best battery" are frequently different answers.
- **§9–§10 — Honest benchmarking.** A real methodology section, built out of measurement failures
  that other people paid for: the harness that manufactured an 80%-vs-20% quality gap, the
  identical recipe that produced a 2.2× throughput difference depending on which macOS built it,
  and the "speed knob" that was actually a memory dial. Closing with a checklist you can paste into
  a benchmark harness.

## What this does *not* cover

- **Model distribution, Background Assets, asset packs, on-demand download and storage
  reclamation.** That is [Part 15 guide 1](../README.md). This guide picks up after the bytes are on disk.
- **KV cache mechanics, prefix reuse and context-window management.** Covered in
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) (Foundation Models) and
  [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) (Core AI states). This guide only cares about the
  *bytes* those caches occupy.
- **Quantization choices.** [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md). Quantization is
  the single largest lever on all the numbers here, and it gets its own treatment.
- **The MLX Swift package setup, concurrency model and `ModelContainer`.** That is
  [Part 13 guide 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md). §5 here covers only the memory-limit APIs and how to
  refcount them, and cross-links.
- **Evaluations and model quality.** [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). §9 covers benchmark
  *methodology* for latency, throughput, memory and energy, and touches quality only where a
  quality harness bug masqueraded as a runtime difference.

## What you need

- **A physical device.** Not the Simulator. There is no jetsam on the Simulator, thermal state is
  meaningless there, and the GPU is not the phone's GPU. Every measurement in this guide that
  matters was taken on hardware, and the two shipping projects it draws on both say so explicitly
  — Noema's README: *"Because GGUF and MLX inference run on-device with Metal, deploy to a physical
  device (or an Apple Silicon Mac) rather than the iOS simulator for full functionality."*
  (✅ **VERIFIED**, `notes/repos/noema-ios.md` §1.)
- **Console.app**, not just the Xcode console. §1 explains why: the message that tells you it was
  jetsam does not appear in Xcode.
- **A Release build** for any number you intend to quote. §9.6 gives you two independently measured
  reasons, one of them a 3× effect.
- **The `com.apple.developer.kernel.increased-memory-limit` entitlement** if you are shipping
  anything larger than a toy. §1.4.

---

## Contents

1. [The jetsam model: your app is killed, not given an error](#1-the-jetsam-model)
   - 1.1 [What jetsam actually is, and what it looks like from inside](#11-what-jetsam-looks-like)
   - 1.2 [`std::bad_alloc` is a jetsam signature on iPadOS](#12-stdbad_alloc)
   - 1.3 [The two OS signals, and reconstructing your real limit](#13-the-two-signals)
   - 1.4 [The increased-memory-limit entitlement and per-device budgets](#14-entitlement-and-budgets)
   - 1.5 [Apple's own published rules of thumb](#15-apples-published-rules)
2. [Why "the model is 4 GB and the phone has 8 GB" is the wrong calculation](#2-the-wrong-calculation)
   - 2.1 [The five terms you are actually paying](#21-the-five-terms)
   - 2.2 [mmap'd versus dirty: the two numbers, and when each one lies](#22-mmap-vs-dirty)
   - 2.3 [KV cache bytes, computed two ways](#23-kv-cache-bytes)
   - 2.4 [MoE: every expert is resident](#24-moe-every-expert-resident)
   - 2.5 [Recurrent and SSM state, and the compute-buffer term](#25-recurrent-state-and-compute-buffers)
   - 2.6 [The two-gate launch check](#26-the-two-gate-launch-check)
3. [Three real failures a size check would have passed](#3-three-real-failures)
   - 3.1 [18 GB on a 12 GB phone: `signal 9` during a 26-minute compile](#31-signal-9)
   - 3.2 [⚠️ Load OK, run dead](#32-load-ok-run-dead)
   - 3.3 [The "depth wall", and an iPad that needed a reboot](#33-the-depth-wall)
4. [Responding to pressure: what a shipping app actually does](#4-responding-to-pressure)
5. [MLX-specific memory: cache limit, memory limit, wired memory](#5-mlx-specific-memory)
6. [Unified memory means another allocator can starve you](#6-another-allocator-can-starve-you)
7. [Thermals, DVFS, and sustained performance](#7-thermals-and-dvfs)
8. [Energy: the ranking that inverts](#8-energy)
9. [Honest benchmarking](#9-honest-benchmarking)
10. [The measurement checklist](#10-the-measurement-checklist)
11. [Declared gaps](#11-declared-gaps)

---

## A note on evidence, before any numbers

Almost every number in this guide is **community-measured**. There is very little Apple-published
performance data for on-device LLM inference, and what exists is not on the axes that matter here
(sustained throughput, energy per token, memory under pressure). The corpus this guide draws on
contains two exceptionally good community sources — a shipping App Store app with six inference
backends behind one enum, and a model-porting project that publishes its own negative results — and
both are attributed as community throughout.

Three standing caveats apply to every table below:

1. **Beta OSes.** Most of these measurements were taken on iOS 27 and macOS 27 betas during
   mid-2026. Betas move. §9.5 documents a case where the *build machine's OS version* changed
   throughput by 2.2× with everything else held constant.
2. **One device, one day.** Where a source measured a same-session control and found the device
   running ~16% faster than in a previous session, this guide says so rather than smoothing it.
3. **Some rows are unverified at source.** The energy table in §8.1 is cited by a repository to a
   report file that is **not present in that repository**. That is stated at the table, not in a
   footnote.

---

## 1. The jetsam model

### 1.1 What jetsam looks like

On macOS, an allocation that cannot be satisfied eventually fails, and you get a `nil`, a `throw`,
a `std::bad_alloc`, or — at worst — swap and a very slow machine. On iOS, iPadOS and visionOS there
is **no swap for your app's dirty pages**, and the kernel's memory manager (jetsam) resolves
pressure by **terminating processes**, highest-footprint-over-limit first.

The consequences for an app doing on-device inference are specific and unpleasant:

- **You do not get an error.** Your process receives `SIGKILL` — signal 9. There is no
  `catch` block, no `deinit`, no chance to flush state, no crash report of the kind you are used
  to reading. From the user's side the app simply vanishes back to the home screen.
- **It can happen during work you thought was safe.** Not just during `malloc`. It happens while a
  compiler is running, while a graph is specializing, on the first inference step of a model that
  loaded cleanly. §3 documents both of those.
- **The Xcode console frequently tells you nothing useful.** One reporter on `apple/coreai-models`
  issue #112 described exactly this: `libc++abi: terminating due to uncaught exception of type
  std::bad_alloc` / `Debug session ended with code 9: killed`, *"no useful Xcode console output."*
  (Community-reported; `notes/repos/issues-coreai-stack.md`.)

> ⚠️ **SILENT FAILURE — a successful load is not a fit test.**
> The single most expensive assumption in on-device ML is that a model which loads is a model that
> runs. It is not. Loading establishes the *weights*; the first inference step additionally
> allocates activations, workspace, and — depending on the runtime — a KV cache that may be
> pre-allocated at full context. A community measurement recorded a 1.8 GB Gemma-4 E2B ANE bundle
> loading on an iPhone 17 Pro in **6.5–8.1 s with no jetsam**, available memory falling
> 6130 → ~2810 MB, and then *"the first inference step is jetsam-SIGKILLed — load ✅ / run ❌."*
> (Community-measured, iPhone 17 Pro / iOS 27 beta, 2026-06-10; `notes/repos/john-rocky-models.md`
> §5.2 citing `aot-and-specialization.md:134-141`.) Nothing in the load path warned. §3.2 works
> through why.

### 1.2 `std::bad_alloc`

The most common way this surfaces on iPadOS during Core AI model loading is a C++ exception that
looks like a bug in the framework and is not:

```
libc++abi: terminating due to uncaught exception of type std::bad_alloc
Debug session ended with code 9: killed
```

✅ **VERIFIED** (community-reported, `apple/coreai-models` issue #112, iPadOS, qwen3-4B;
`notes/repos/issues-coreai-stack.md`). The reporter resolved it themselves after the maintainer
suggested launching outside Xcode:

> "I used the **Console app** and captured a key message: **`Out of Memory`**. I then added the
> **`Increased Memory Limit` entitlement**, and the app no longer crashes."

Two operational lessons, both cheap:

1. **When an on-device model dies mysteriously, open Console.app and filter on your process.** The
   jetsam record is there. The Xcode console is not where the OS writes this.
2. **`std::bad_alloc` from a model load on iOS/iPadOS should be read as "out of memory", not as
   "framework bug".** It is what a C++ allocator does when the kernel refuses the mapping, and on
   iOS the refusal is a budget decision, not a hardware one.

The same repository's issue #77 has a harsher variant on an **iPad Pro M4 with 8 GB**, running
Flux2 diffusion under iPadOS 27 beta 2/3 (community-reported, `notes/repos/issues-coreai-stack.md`):

> "When this happens, my iPad is basically in a lost state. Any further attempt to start the app
> via Xcode leads to just: `terminating due to uncaught exception of type std::bad_alloc` … I can
> also not open the app again from the homescreen. **Only thing that helps is restarting the
> iPad.**"

And the uncompiled (JIT) path on that 8 GB device failed with a message that is worth memorising
because it names the actual number:

```
MemrefBufferizationRuntime.mm:202: error 'createMemrefHeap: newHeapWithDescriptor returned nil
  (size=3847225344, manualPlacement=1)'
```

A single **3.85 GB heap request** on an 8 GB iPad. The maintainer's note in the same thread is the
tell: *"The iPads I used to test this model were all **16GB** versions (M1 -> M5)."* A model that is
comfortable on every device the vendor tested on can be un-shippable on the device tier below.

### 1.3 The two signals

There are exactly two numbers you need, and they are not interchangeable.

**`os_proc_available_memory()`** — how many more bytes this process may allocate before the kernel
starts objecting. Apple's own Core AI guidance tells you to use it: `references/guidance.md` in
`apple/coreai-models` says to *"use `os_proc_available_memory()` at runtime"*
(✅ **VERIFIED**, Apple-published, `notes/repos/apple-coreai-models.md` §15.1).

**`phys_footprint`** — from `task_info(… TASK_VM_INFO …)`, the process's current dirty,
jetsam-relevant footprint. This is the number jetsam scores you on.

A shipping app bridges both from C, because neither has a first-class Swift API. This is Noema's
`GGUFScanner.c`, reproduced with its structure intact (✅ **VERIFIED**, community source,
`notes/repos/noema-ios.md` §10.1):

```c
// GGUFScanner.c — the two OS memory signals, bridged for Swift.
#include <mach/mach.h>
#include <mach/task_info.h>
#include <os/proc.h>
#include <TargetConditionals.h>
#include <stddef.h>

/// The process's dirty physical footprint — the number jetsam scores you on.
size_t app_memory_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self_, TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (size_t)info.phys_footprint;
}

/// How much more this process may allocate.
size_t app_available_memory(void) {
#if defined(TARGET_OS_OSX) && TARGET_OS_OSX
    // macOS has no per-process budget; approximate with host free + inactive pages.
    // (host_statistics64 HOST_VM_INFO64: free_count + inactive_count, times host_page_size)
    return macos_free_plus_inactive_bytes();
#else
    return os_proc_available_memory();
#endif
}
```

and consumed from Swift without a bridging header, via `@_silgen_name`:

```swift compile:27
@_silgen_name("app_available_memory")  fileprivate func c_app_available_memory() -> UInt
@_silgen_name("app_memory_footprint")  fileprivate func c_app_memory_footprint() -> UInt
```

✅ **VERIFIED** — Noema consumes these in **four** separate files (`ModelRAMAdvisor`,
`LiveMemoryPressureView`, `OverfitMemoryGovernor`, `OverfitGovernorController`).

🟡 **RECONSTRUCTED** — the `#include` list above and the `macos_free_plus_inactive_bytes()` helper
name are ours; the notes record the *behaviour* of the macOS branch (`host_statistics64` with
`HOST_VM_INFO64`, summing `free_count + inactive_count` and multiplying by `host_page_size`) but
not its literal spelling. The two exported function names and the two signal calls are verbatim.

#### Reconstructing the process limit

Neither signal is the limit. **Together they are:**

```swift illustrative
/// The process allocation limit, reconstructed live.
/// Community pattern, from ModelRAMAdvisor (notes/repos/noema-ios.md §10.3).
static func liveProcessMemoryLimitBytes(liveAvailable: Int64?,
                                        currentFootprint: Int64?) -> Int64? {
    guard let liveAvailable, let currentFootprint else { return nil }
    return liveAvailable + currentFootprint
}
```

✅ **VERIFIED** as a signature and as a formula (`notes/repos/noema-ios.md` §10.3). The rationale
in that source is worth carrying verbatim, because it settles a question people get wrong:

> "A positive `os_proc_available_memory()` reading is **AUTHORITATIVE** on iOS and is never reduced
> by the static device table."

In other words: a hardcoded per-device RAM table is a *fallback for when the live reading is
unavailable*, never an override for it. Storage configuration, OS version, what else is running,
and whether you hold the entitlement all move the real limit; the live reading already accounts for
all of them.

Noema wraps this in a snapshot type that records which of the two paths produced the number, which
is exactly the right shape — you want to know at the call site whether you are looking at a
measurement or a guess:

```swift illustrative
struct MemoryBudgetSnapshot {
    let bytes: Int64?
    let isLiveProcessLimit: Bool   // false ⇒ this came from the static device table
}

static func currentMemoryBudgetSnapshot() -> MemoryBudgetSnapshot
// iOS: live limit when available.
// macOS / Catalyst: DeviceRAMInfo.conservativeLimitBytes()
```

✅ **VERIFIED** (`notes/repos/noema-ios.md` §10.3, community source).

### 1.4 Entitlement and budgets

**`com.apple.developer.kernel.increased-memory-limit`** is not optional for this class of app.

```xml
<!-- Noema.entitlements — the memory-relevant subset -->
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
<key>com.apple.developer.background-tasks.continued-processing.gpu</key><true/>
<key>com.apple.developer.private-cloud-compute</key><true/>
```

✅ **VERIFIED** (`notes/repos/noema-ios.md` §2, read from `Noema/Noema.entitlements`) for the three
keys in that block. That source
annotates the first line: *"`kernel.increased-memory-limit` — **mandatory** for shipping big local
LLMs on iOS."* It is independently corroborated: **every** LLM, VLM and Stable Diffusion sample app
in `mlx-swift-examples` enables it (✅ **VERIFIED**, `notes/repos/mlx-swift-examples.md` §5), and
`apple/coreai-models` issue #112 above was resolved by adding it.

`background-tasks.continued-processing.gpu` is the **iOS 26** `BGContinuedProcessingTask` GPU class,
relevant if you want long GPU work to survive backgrounding; it is Part 15 guide 1's territory but
it belongs on the same checklist. The separate
`background-tasks.continued-processing.inference` entitlement is required for background Neural
Engine access through Core AI, Core ML, or MPS Graph — ✅ **VERIFIED (Apple docs)**, verbatim from
the entitlement page: *"The system also requires the entitlement for any Neural Engine access while
your app is in the background, regardless of whether it's running a continued background task. You
can perform inference with Core AI, Core ML, or Metal Performance Shaders
Graph."*[^background-inference-entitlement] These entitlements authorize background
hardware access; they do **not** set inference priority or force placement on a compute unit. Keep
placement preferences in Core AI `SpecializationOptions` and verify actual placement in
Instruments.[^background-inference-entitlement]

```xml
<!-- Apple-documented addition for background Neural Engine inference -->
<key>com.apple.developer.background-tasks.continued-processing.inference</key><true/>
```

#### Per-device budgets, and the storage-tier surprise

Noema keeps a hardcoded table mapping `utsname().machine` to a device name, RAM figure and process
limit, used only as the fallback path. A representative slice (community-measured / community-
compiled, `notes/repos/noema-ios.md` §10.2):

| Identifier | Device | RAM | App budget |
|---|---|---|---|
| `iPhone17,5` | iPhone 16e | 8 GB | ~7 GB (7000 MiB) |
| `iPhone18,3` | iPhone 17 | 8 GB | ~7 GB |
| `iPhone18,5` | iPhone 17e | 8 GB | ~7 GB |
| `iPhone18,1` | iPhone 17 Pro | 12 GB | ~11 GB |
| `iPhone18,2` | iPhone 17 Pro Max | 12 GB | ~11 GB |
| `iPhone18,4` | iPhone Air | 12 GB | ~11 GB |
| `iPad16,8`–`iPad16,11` | iPad Air (M4) | 12 GB | ~11 GB |
| `RealityDevice14,1` | Apple Vision Pro | 16 GB | ~15 GB (15000 MiB) |

Two details from that table are load-bearing:

- **A "conservative" budget subtracts a fixed reserve.** `conservativeLimitBytes()` returns
  `limitBytes - 512 MiB`, floored at zero. If you plan to the limit you will hit it.
- ⚠️ **Storage tier changes the RAM tier on iPad.** iPad Pro models with **1 TB or 2 TB** storage
  are bumped to 16 GB RAM / ~15 GB budget in that table, derived from
  `attributesOfFileSystem[.systemSize]` bucketed into decimal-GB tiers (64/128/256/512/1024/2048).
  This is a real device-configuration fork that a model identifier alone does not capture, and it
  is one more reason to trust the live reading over the table.

On macOS the same code uses `sysctlbyname("hw.model")` and budgets `physicalMemory - 1 GiB`.

Also relevant to hardware gating rather than memory: the same file keeps a hard list of pre-A13
devices (iPhone X/XS/XR, first- and second-generation 11" iPad Pro, third- and fourth-generation
12.9", iPad Air 3, iPad 7/8, iPad mini 5) on which `supportsGPUOffload == false`, blocking MLX
entirely and forcing float16 — *"Pre-A13 devices cannot reliably JIT MLX bfloat16 kernels. Force
float16 on these models to avoid Metal compiler crashes."* (✅ **VERIFIED**, community source.)

#### A fact that changes what your numbers mean

`SystemLanguageModel` — Apple's built-in on-device model — runs **out of process**. Apple staff
confirmed on Developer Forums thread 833575 that it is therefore *free of extension memory limits*;
the same thread notes that **XPC-restricted extensions cannot use FoundationModels at all**
(✅ **VERIFIED**, Apple-staff answer, `notes/forums/forum-pain-points.md` §5 and Cluster K).

The consequence for measurement is immediate and frequently missed. A community benchmark harness
measuring Apple's own model recorded **27 MB peak in-process memory** — and said so honestly:

> "**Peak memory is in-process only.** The model lives in Apple's system process, not ours, so
> **27 MB is the harness overhead — not the true model footprint.**"

(Community-measured, `notes/web/community-blogs.md` §2.9.) If you put `SystemLanguageModel` in a
memory comparison against MLX or Core AI without that caveat, you will produce a chart in which
Apple's model uses 1% of the memory of every competitor. That chart is wrong, and the axis is the
problem, not the model.

### 1.5 Apple's published rules

Apple publishes very little here, but what it does publish is worth quoting exactly.
`references/guidance.md` in `apple/coreai-models` gives platform rules (✅ **VERIFIED**,
Apple-published, `notes/repos/apple-coreai-models.md` §15.1):

- **iOS:** *"Keep models under 2 GB"*
- **macOS:** *"Leave at least 6 GB of RAM headroom"*
- Use **`os_proc_available_memory()`** at runtime.
- Use **`.default`** specialization options unless you deliberately pin a compute unit.

The 2 GB iOS figure is a *model* figure, not a footprint figure, and §2 explains why the difference
matters — but as a first filter it is a good one, and it sits well below what the community has
tried and had killed. The 6 GB macOS headroom rule is worth taking literally: §6 shows a case where
a different framework's allocator had already consumed ~40 GiB on a 48 GB machine.

---

## 2. The wrong calculation

Here is the calculation almost everyone does first:

> The quantized model file is 4.0 GB. The phone has 8 GB. Therefore it fits, with 4 GB to spare.

Every clause of that is defensible and the conclusion is still wrong, for five separate reasons
that compound. This section takes them one at a time and ends with the two-gate check that a
shipping app actually runs before it will let a user load a model.

### 2.1 The five terms

Model residency is a **sum**, and the weights are only the first term:

```
resident ≈ weights
         + KV cache (grows with context, and may be pre-allocated at full context)
         + recurrent / SSM state (context-independent, but F32 and per-layer)
         + activations / compute buffers (grow with batch × sequence, and with graph shape)
         + auxiliary models (vision projector, prefill companion, draft model, embedder)
         + fixed framework overhead
         + a transient reserve for the spikes you did not model
```

Noema models exactly this, and the shape of its estimator is more instructive than any prose
(✅ **VERIFIED**, community source, `notes/repos/noema-ios.md` §10.3):

```swift illustrative
struct EstimateBreakdown {
    let weights, kvCache, recurrentState, computeBuffers,
        visionProjector, auxiliaryModels, fixedOverhead, safetyMargin: Int64
    var estimate: Int64 { saturatedSum([...]) }
}

private static let fixedRuntimeOverhead:   Int64 = 200 * 1_048_576   // 200 MiB
private static let defaultTransientReserve: Int64 = 192 * 1_048_576  // 192 MiB
static let pagedStagingEstimateBytes:      Int64 =  64 * 1_048_576   //  64 MiB
```

Note `saturatedSum` — this code assumes it may overflow, which tells you how large these numbers
get. Note also that the fixed overhead and the transient reserve together are **almost 400 MiB
before a single weight byte**, and that the transient reserve is *calibrated from observed
launches* rather than fixed:

```swift illustrative
static func calibratedTransientReserveBytes(defaults: UserDefaults = .standard) -> Int64
static func recordSuccessfulGGUFLaunch(estimatedIncrementalBytes:
                                       baselineFootprintBytes:
                                       peakFootprintBytes:)
// samples persisted under "ggufMemoryTransientReserveSamples.v1"
```

✅ **VERIFIED** (signatures, `notes/repos/noema-ios.md` §10.3). This is a pattern worth stealing:
**record the delta between your estimate and the actual peak on every successful launch, and let
the reserve converge on the truth for the devices your users actually have.** No amount of desk
modelling substitutes for that.

The per-format weight multiplier in the same estimator is small but revealing:

| Format | Weights multiplier |
|---|---|
| GGUF | 1.05 |
| MLX | 1.10 |
| ExecuTorch | 1.10 |
| Core ML / ANE | 1.00 |
| Foundation Models | 1.00 |
| Core AI | 1.00 |

with the rationale: *"With `mmap` on (the default for GGUF), the quantized weights are mapped
directly and stay quantized in RAM, so resident weights ≈ file size."* (✅ **VERIFIED**,
community source.) The 1.00 entries for ANE/AFM/Core AI are not a claim that those runtimes are
free — they are a claim that this estimator's *other* terms carry their cost.

### 2.2 mmap vs dirty

This is the distinction that makes memory numbers incomparable across runtimes, and it is the
single most common way benchmark tables mislead.

- **Clean, read-only mmap'd pages** (a GGUF or `.aimodel` file mapped from disk) are **not charged
  to `phys_footprint`**, because the kernel can drop and re-fault them. They *do* show up in RSS.
- **Dirty pages** — anything you wrote, anything wired, KV cache, activations — are charged, and
  are what jetsam counts.

A community benchmark of Apple's own Core AI artifacts spells out the reporting rule
(✅ **VERIFIED**, community-measured, M4 Max 128 GB / macOS 27 beta, `notes/repos/john-rocky-models.md`
§7.2):

> "`/usr/bin/time -l`'s 'peak memory footprint' counts only **dirty** pages — the mmap'd weight
> file shows up in 'maximum resident set size' instead. Report **RSS** for 'how much RAM do I
> need', **footprint** for 'how much does inference itself allocate'."

The same corpus states the jetsam-side version even more directly:

> "`phys_footprint` is the **jetsam-relevant dirty number** and **excludes clean read-only-mmapped**
> [pages] … **Report both numbers, labeled**, if footprint matters for your jetsam budget."

And a cross-runtime benchmark that put seven runtimes in one table had to footnote its own memory
column for exactly this reason (community-measured, iPhone 17 Pro, `notes/web/community-blogs.md`
§2.8):

> "† mmap'd weights: clean pages aren't charged to `phys_footprint`, so these 'memory' cells are
> not comparable with runtimes that wire their weights — footnote, don't rank."

The scale of the discrepancy is not subtle. The same gpt-oss-20b model measured on the same machine
gave **MLX Metal peak 14.6 GB vs Core AI 33.9 GB RSS** — and the source immediately disclaimed the
comparison: *"not directly comparable; RSS includes the mmap'd 13 GB weight file."*
(Community-measured, M4 Max 128 GB, macOS 27 beta; `notes/repos/john-rocky-models.md` §7.2.)

> ⚠️ **SILENT FAILURE — mmap'd weights are free until they are not.**
> "Clean pages are reclaimable" is true and is not the same as "clean pages are free". As inference
> touches weights they become resident, and on unified memory that residency competes with
> everything else. Noema's own gate documentation says this from device data:
> *"Allocation headroom alone is insufficient on unified memory: mmap-backed weights become
> resident as inference touches them. **Device testing on 6 GB-class process limits shows that
> allowing a broad logical overcommit can launch but then OOM at large contexts.**"*
> (✅ **VERIFIED**, community source, `notes/repos/noema-ios.md` §10.4.) An app that checks only
> `os_proc_available_memory()` will pass models that die two thousand tokens into a conversation.

Noema resolves this with an explicit **overcommit ratio** rather than by pretending mapped pages
are either free or fully charged:

> "Unlike the hard launch gate, this compares the complete logical working set with the process
> limit so mmap-backed weights still contribute to unified-memory pressure. Standard GGUFs get only
> a small **11% logical overcommit** because clean mapped pages are reclaimable. Ultra-low-bit
> Metal kernels do not get that allowance: device launches show their runtime workspace is much
> less predictable than the compact Q1/Q2 file size suggests."

→ ratio `1.11` on iOS normally, `1.0` on macOS or when an extra Metal safety reserve is in play.
✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §10.3). The second sentence is the
interesting one: **the more aggressively quantized the weights, the *less* the file size predicts
the footprint**, because the runtime workspace does not shrink with the weights.

There is one documented case where the usual "mmap, never copy" instinct is exactly backwards. A
Gemma-4 per-layer-embedding table bound as a static input buffer measured better as an **owned
`storageModeShared` MTLBuffer** than as a read-only mmap:

> "Read each PLE table file once into an **OWNED `storageModeShared` MTLBuffer** (**owned beats a
> read-only mmap here — a no-copy mapping pays a large per-encode residency tax**, and these are
> bound on every step). ~2.35 GB for E2B."

(Community-measured, `notes/repos/john-rocky-models.md` §9.1, `gemma4-ple-static-input-fm-stack.md`.)
The mechanism named is per-encode residency: a buffer bound on every dispatch pays a mapping cost
each time. Do not generalise this to weights you touch once per token; do take it as evidence that
"mmap is free" is a heuristic, not a law.

### 2.3 KV cache bytes

Two independent sources give you the same arithmetic, which is reassuring. Use it.

**Formulation A** — from `mlx-swift-lm`'s own `wired-memory.md` documentation
(✅ **VERIFIED**, `notes/repos/mlx-swift-lm.md` §17):

```
elements per token per layer = 2 * kvHeads * headDim
layer bytes                  = tokens * elementsPerTokenPerLayer * bytesPerElement
total KV bytes               = layerBytes * numAttentionLayers
```

with `bytesPerElement`: **2** for FP16/BF16, **1** for INT8, **0.5** for INT4.

**Formulation B** — Noema's exact path when GGUF metadata is available, which separates K and V
because they can have different head dimensions (✅ **VERIFIED**,
`notes/repos/noema-ios.md` §10.3):

```
per_token = layers · ( n_kv_heads · head_dim_k · k_bytes
                     + n_kv_heads · head_dim_v · v_bytes )
```

`layers` resolves through `moeInfo.attentionLayerCount ?? totalLayerCount ?? layerCount ?? 32` —
note that for a hybrid model the **attention** layer count is what matters, not the total, because
recurrent layers do not carry KV. `head_dim` comes from `key_length` / `value_length` when present,
otherwise `hidden / head_count`. Where metadata is missing entirely, the fallback heuristic is
`kvDim = hidden × 0.34` for GGUF, `× 0.5` otherwise — and you should treat any estimate that lands
on that branch as a guess, not a number.

Worked example, so the magnitude is concrete. Take a 4B-class model with 32 attention layers,
8 KV heads, head dim 128, FP16 KV:

```
elements/token/layer = 2 × 8 × 128            = 2,048
bytes/token/layer    = 2,048 × 2              = 4,096
bytes/token          = 4,096 × 32             = 131,072   (128 KiB per token)
at   4,096 tokens                             ≈ 512 MiB
at  32,768 tokens                             ≈   4 GiB
at 131,072 tokens                             ≈  16 GiB
```

A 4B model whose weights are 2.1 GB at 4-bit can therefore need **eight times its own weight budget
in KV alone** at a 128K context. This is why "the model is 4 GB" is not a memory plan: context
length is a first-class memory parameter, and on several of the runtimes here it is a *launch-time*
parameter you cannot change later.

#### Pre-allocation is the trap

Core AI's engine layer exposes the choice explicitly. `EngineOptions` carries a `KVCacheStrategy`
(✅ **VERIFIED**, `apple/coreai-models` source as vendored, `@available(iOS 27.0, macOS 27.0,
tvOS 27.0, watchOS 27.0, visionOS 27.0, *)`; `notes/repos/noema-ios.md` §5.2):

```swift illustrative
public struct EngineOptions: Sendable {
    public let variant: String?                  // nil = auto
    public let kvCacheStrategy: KVCacheStrategy  // default .auto
    public let kvCacheSize: Int?
    public init(variant: String? = nil,
                kvCacheStrategy: KVCacheStrategy = .auto,
                kvCacheSize: Int? = nil)
    public func resolvedKVCacheSize(maxContextLength: Int) -> Int?
}

public enum KVCacheStrategy: String, Codable, Sendable, CaseIterable {
    case auto = "auto"
    case fixedSize = "fixed_size"
    case growing = "growing"
    case chunked = "chunked"

    public func defaultSize(maxContextLength: Int) -> Int? {
        switch self {
        case .auto:      nil
        case .fixedSize: maxContextLength
        case .growing:   256
        case .chunked:   maxContextLength
        }
    }
}
```

Apple's own documentation comments on these cases are the memory advice, verbatim:

- `.auto` — *"uses a 256-token initial cache for dynamic-shape models and the full context length
  for chunked-static models."*
- `.fixedSize` — *"**Avoid `.fixedSize` unless you need a known upper bound.** It pre-allocates the
  cache at the full `maxContextLength`, which can consume several gigabytes on long-context models
  and slows each decoding step because every iteration operates on the full-size KV."*
- `.growing` — *"Start small, grow exponentially (2×)… ~20 ms stall on growth (amortized
  O(log₂ N))"*; auto-selected *"for models exported with `--dynamic-sized-kvcache-gpu`"*.
- `.chunked` — **not yet implemented.**

✅ **VERIFIED** (Apple source comments in the `coreai-models` Swift package, as recorded in
`notes/repos/noema-ios.md` §5.2). Read `.fixedSize`'s warning again: it costs you memory **and**
speed. It exists for the case where you need a hard ceiling for admission control, which is a real
case — but it is not a default.

### 2.4 MoE: every expert resident

This one reverses an intuition that sounds right.

A Mixture-of-Experts model activates only *k* of *E* experts per token. It is natural to assume the
memory follows the activation. It does not, on any of the mmap-based paths:

> "The quant file's bytes are what occupy RAM: `mmap` maps the whole file (so **every MoE expert is
> resident, not just the active ones**)… There is therefore no 'active experts only' reduction for
> memory — **the earlier active-expert accounting under-counted MoE footprint.**"

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §10.3 — and note that this is the
source *correcting its own earlier model*, which is the kind of citation you want).

The same trap has a Python-side twin in mlx-lm. `mlx_lm.load` defaults to `lazy=False`, which calls
`mx.eval(model.parameters())` and **materializes the full stacked `(num_experts, ...)` expert table
at load time** — a measured **18.2 GB spike on Qwen3.6-35B-A3B-4bit before a single token**
(community-measured, `notes/repos/issues-mlx-stack.md` §8.1). The fix is `load(lazy=True)` plus
dropping the full-table references before anything forces their evaluation. There is a further
sharp edge recorded in the same thread that generalises well beyond MoE:

> "**A prefix slice of an `mx.array` is a view that pins the whole parent buffer**, so slicing does
> not actually free the rest of the table."

If you are doing expert offload or any form of partial residency, seed the resident set from your
fetch function, not by slicing the loaded weight.

And a counterweight, so this is not read as "MoE is hopeless on device": dropping a MoE's experts
from int8 to int4 measured **39 → 170 tok/s and 8.8 → 5.0 GB** on an M4 Max — a *superlinear* speed
effect, because the int4 path stopped full-reading the expert table. The 5.0 GB variant with a
custom gather kernel landed at **4.7 GB, described by its author as "iPhone-jetsam-safe"**, and ran
at ~32 tok/s on an iPhone 17 Pro. (Community-measured, `notes/repos/john-rocky-models.md` §5.3.)
Quantization is the memory lever; residency accounting only tells you whether you pulled it hard
enough.

### 2.5 Recurrent state and compute buffers

**Recurrent / SSM state.** Hybrid architectures (Qwen3.5-class gated DeltaNet, Mamba2, Granite 4-H,
LFM2.5) carry per-layer running state that is **context-independent** — it does not grow with the
conversation — but is **F32** and per-layer, so it is not negligible:

```
convolutionState = (ssmConvKernel - 1) * (ssmInnerSize + 2 * ssmGroupCount * ssmStateSize)
linearState      = ssmStateSize * ssmInnerSize
bytes            = recurrentLayerCount * (convolutionState + linearState) * 4.0   // F32
```

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §10.3).

This is the *good* news about hybrids on device: their state does not scale with context the way
KV does. The bad news is in [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) and is not a memory
story — a running scan cannot be rewound, so hybrid and linear-attention models **forfeit prefix
caching entirely and must re-prefill every turn**. You trade memory growth for prefill cost. Budget
accordingly, and see §9.4 on why prefill is the metric that matters for agentic workloads.

**Compute buffers.** Noema's GGUF-path model is worth reproducing because it names the terms:

```swift illustrative
tokens        = min(contextLength, evaluationBatchSize, physicalBatchSize)
activationScalarsPerToken = 6*hidden + 2*feedForward
liveBufferFactor = (recurrentLayerCount ?? 0) > 0 ? 5.0 : 3.0   // hybrid graphs keep more live state
activations   = tokens * activationScalarsPerToken * 2.0 * liveBufferFactor      // f16
vocabularyProjection = vocab * 4.0                    // ONE row: server requests 1 output/seq
graphBookkeeping     = 16 MiB + layers * 512 KiB
nonFlashAttention    = flashAttention ? 0 : tokens * min(context, 8192) * heads * 2.0
```

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §10.3). Two things to take from it:

- **Hybrid graphs are modelled at 5/3 the live-buffer cost of pure attention.** That is an empirical
  constant from a shipping app, not a derivation, but it is the right direction.
- **Turning off flash attention adds a `tokens × context × heads` term.** On a 32-head model at
  4096 tokens and 4096 context that is ~1 GiB of pure attention scratch. If your runtime silently
  falls back off the fused path — and [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md) documents that
  it can — you pay this without being told.

**Auxiliary models** are the term people forget entirely. A vision projector is modelled at
`fileBytes * 1.05 + 96 MiB`. A speculative-decoding draft model is a second set of weights. And a
Core AI chunked-prefill companion bundle is a *second graph* — which is why Noema's resolver
prefers the int8 companion over the fp16 one with an explicitly memory-driven rule:

> "When both int8 and fp16 companions exist the **int8** one wins: the fp16 prefill graph plus the
> decode monolith exceed the app memory budget on device."

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §4.9).

### 2.6 The two-gate launch check

Put all of the above together and you get the check a shipping app actually runs. It has **two
gates, and passing only the first is how apps launch and then die later.**

```swift illustrative
// Gate 1 — incremental allocation must fit the live process budget.
//
// mmap-backed model buffers are NOT charged against os_proc_available_memory()
// EXCEPT for paged launches (which force mmap off), and on macOS.
let chargeMappedModelBuffers: Bool
#if os(macOS) || targetEnvironment(macCatalyst)
chargeMappedModelBuffers = true
#else
chargeMappedModelBuffers = (serverConfiguration?.pagedMode ?? .off) != .off
                        || exact.paged != nil
                        || pagedBackfill != nil
#endif

let estimated = incrementalProcessAllocationBytes(
    modelBytes: …, contextBytes: …, computeBytes: …,
    projectorBytes: …, speculativeBytes: …,
    chargeMappedModelBuffers: chargeMappedModelBuffers) + pagedExtraBytes

let required  = estimated + runtimeTransientReserveBytes(runtimeConfiguration: …)
let available = planningBudgetBytes()
guard required <= available else { return .doesNotFit }

#if !os(macOS)
// Gate 2 — the TOTAL LOGICAL WORKING SET must fit the advisory limit.
// This is the gate that catches "launches fine, OOMs at 3000 tokens".
let totalWorkingSet = exact.totalBytes + pagedExtraBytes + transientReserve
return totalWorkingSet <= advisoryWorkingSetLimitBytes(…) ? .fits : .doesNotFit
#endif
```

✅ **VERIFIED** as structure and rationale (community source, `notes/repos/noema-ios.md` §10.4).
Three implementation details from that source that make the difference between this working and
this being theatre:

1. **The size estimate comes from the runtime, not from the app.** Noema calls llama.cpp's
   *no-allocation* sizing entry point (`LlamaServerBridge.memoryEstimate`) rather than modelling
   the graph itself. If your runtime exposes a dry-run sizing call, use it; a model of someone
   else's allocator is a model of last year's allocator.
2. **It runs on a detached utility task behind a process-global lock, with double-checked caching.**
   Sizing a multi-gigabyte model is not free, and you will be asked for the answer from several
   places at once.
3. **The failure states are named, not booleanised.** `GGUFLaunchFitAssessment.Status` is
   `.fits`, `.doesNotFit`, `.unavailable` — and `.unavailable` carries a message
   (`"metadata_not_ready"`, `"memory_sizing_unavailable"`, `"invalid_memory_sizing_response"`,
   `"memory_sizing_failed"`). "We could not determine whether this fits" is a *third* answer and
   your UI needs it, because collapsing it into either of the other two is how you either block
   working configurations or ship crashes.

---

## 3. Three real failures

These are not hypotheticals. Each one is a recorded, community-measured device failure, and each
one would have passed a naive "file size vs RAM" check.

### 3.1 `signal 9`

**What was attempted:** running a **Qwen3.6-35B int4** Core AI bundle — **18 GB** — on an
**iPhone 17 Pro**, which has ~12 GB of RAM and an entitled process budget in the ~11 GB region.

**What happened:** `signal 9` — jetsam OOM — *"killed during the ~26-min cold compile."*

**Community-measured**, iPhone 17 Pro (A19 Pro, `iPhone18,1`), iOS 27 beta, 2026-07-01;
`notes/repos/john-rocky-models.md` §7.4 citing `dense-int4km-flagship-session-findings.md:53-54`.
The author's own summary of the ceiling this establishes:

> "⚠️ On-device (A19) model-size ceiling ≈ **5–6 GB** (int4-8B-class). LFM-8B (5 GB) runs;
> **Qwen3.6-35B int4 (18 GB) → `signal 9` (jetsam OOM)** on the iPhone 17 Pro's ~12 GB RAM …
> **The flagship 35B cannot run on the phone.**"

Three things are worth extracting, because the headline ("18 GB doesn't fit in 12 GB") is the least
interesting part:

1. **It died during compilation, not during inference.** The on-device specialization step — Core
   AI turning a portable `.aimodel` into a device-specific compiled graph — is itself a large,
   long-running memory consumer. Twenty-six minutes of it. Your memory gate has to cover the
   *compiler*, not just the model. §9.7 covers the AOT escape hatch that removes this step.
2. **The practical ceiling is roughly half the RAM, not most of it.** ~5–6 GB on a 12 GB phone.
   That is consistent with Apple's own published *"keep models under 2 GB"* iOS guidance being
   conservative-but-directionally-right rather than arbitrary, and with the ~4.7 GB MoE variant its
   author called "iPhone-jetsam-safe".
3. **A 26-minute compile is a product failure even when it succeeds.** No user waits that long, and
   nothing in the API surface will tell you it is going to happen. See also the measured
   **194-second** cold ANE specialization of a 3 GB `.aimodelc` in §9.7.

### 3.2 Load OK, run dead

This is the one to internalise.

**What was attempted:** a **35-layer Gemma-4 E2B host-cache monolith**,
`gemma4_e2b_hostcache_L35_int8.aimodel`, **1.8 GB**, AOT-compiled for iOS ANE architecture `h18p`
(compile exited 0, ~4.0 GB host RSS on the Mac), sideloaded to an **iPhone 17 Pro** and loaded with
`cu=ane`.

**What happened, in order:**

- The model **loaded successfully** in **6.5–8.1 s**, with **no jetsam**.
- Available memory fell from **6130 MB → ~2810 MB**.
- **The first inference step was jetsam-SIGKILLed.**

Verbatim from the source: *"the first inference step is jetsam-SIGKILLed — **load ✅ / run ❌**."*
And the diagnosis: *"The ANE load leaves only ~2.8 GB headroom (the GPU path leaves ~6.0 GB for the
same-size core) and the first-step working set blows through it."*

**Community-measured**, iPhone 17 Pro / iOS 27 beta, verified 2026-06-10 against Xcode `27A5194q`,
Metal Toolchain `v27.1.5194.15` / `metal 32023.917`, macOS 27.0 `26A5353q`;
`notes/repos/john-rocky-models.md` §5.2 citing `aot-and-specialization.md:134-141`.

> ⚠️ **SILENT FAILURE — the compute unit changes your headroom by 2×, and nothing says so.**
> The *same* 1.8 GB core left **~2.8 GB** of headroom on the ANE path and **~6.0 GB** on the GPU
> path. That is not a rounding difference; it is the difference between a model that runs and a
> model that is killed on its first token. There is no API that reports "loading via this compute
> unit will cost you 3.2 GB more". You find out by loading it on a device and reading
> `os_proc_available_memory()` on both sides of the load — which is exactly what §10's checklist
> asks you to do.

The practical protocol that falls out of this:

```swift prelude:guide-context
// Minimum viable fit test. Anything less is not a fit test.
let before  = availableMemoryBytes()          // os_proc_available_memory()
try await model.load()
let afterLoad = availableMemoryBytes()
_ = try await runOneToken()                   // ← THE STEP EVERYONE SKIPS
let afterFirstStep = availableMemoryBytes()

log("load cost \(before - afterLoad) B; first step cost \(afterLoad - afterFirstStep) B; "
  + "headroom now \(afterFirstStep) B")
```

Note what this measures that a load-only test does not: **the first-step working set**. On a
host-cache graph this includes the static KV allocation; on a dynamic graph it includes whatever
the specializer decided the activation buffers should be for that shape. Neither is knowable from
the bundle.

Noema encodes a related discipline in its Core AI prewarm path, and the comment is the lesson:

```swift prelude:guide-context
guard CoreAIDecoder.hostCacheCapacity(in: descriptor) == nil else {
    print("[CoreAI] Skipping prewarm for host-cache graph; it would allocate the static KV cache.")
    return
}
```

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §4.5). Prewarming is normally good —
it gets one state shape specialized at load time rather than on the user's first message — but on a
host-cache export it triggers exactly the allocation you are trying to defer. **The optimisation
and the hazard are the same code path**, distinguished only by the graph's shape.

### 3.3 The depth wall

Two more failure modes worth naming, both less well characterised than the two above and both worth
designing around anyway.

**The Core AI "depth jetsam wall" on iPhone.** A community benchmark project running seven runtimes
on an iPhone 17 Pro found that its standard deep-generation protocol **jetsams Core AI**, and had
to run Core AI on a shallower protocol to get any number at all (community-measured,
`notes/web/community-blogs.md` §2.5):

> "The standard deep protocol **jetsams** Core AI — that failed run stays on record per fairness
> rule #4."
> "Core AI's 0.352 is a shallow-rep reference (**192 tok/rep to stay under its depth jetsam
> wall**; the shallow bias *favors* it — still ~2.9× LiteRT)."

The same source's own summary of the state of knowledge is honest and worth repeating:
*"Core AI's 'depth jetsam wall' on iPhone — **real, measured, but no one has characterized where it
is or whether an API controls it.**"*

🔴 **GAP — where the Core AI depth wall is, and whether any API moves it.**
What is unknown: the token depth at which a given Core AI bundle on a given device will be jetsammed;
whether it is a function of `KVCacheStrategy`, of `kvCacheSize`, of the export's chunking, or of the
engine's pipeline depth; and whether it can be raised at all from the app side.
What would resolve it: a depth sweep on a single device and bundle, stepping generation length and
recording `phys_footprint` and `os_proc_available_memory()` at each step until the kill, repeated
across `kvCacheStrategy` values — plus the same sweep on `COREAI_CHUNK_THRESHOLD` (§9.6).
**Safe default until then:** cap generation length explicitly on iOS rather than letting the model
run to EOS; treat `.fixedSize` KV as a hard ceiling you *chose* rather than a default you inherited;
and instrument every generation with a footprint sample so that when a user's device dies you have
the depth at which it happened.

**A device that needs a reboot.** The iPad Flux2 case from §1.2 is the worst-case shape of this
class: an intermittent `SIGABRT` (~1 in 20–50 generations) escalating to a state where the app
cannot be relaunched from Xcode *or* from the home screen until the iPad is restarted. The proximate
cause in that thread turned out to be a leak — the diffusion pipeline was loading a fresh
`InferenceFunction` on **every inference call (~30 per generation)** as a workaround for an MPSGraph
buffer-caching bug that had since been fixed, and the workaround *"caused GPU memory to accumulate
across generations, leading to SIGABRT after ~20 images"* (community-reported and then fixed in PR
#110; `notes/repos/issues-coreai-stack.md`).

Two lessons, both generalisable:

- **A workaround for a fixed bug is a leak.** When you carry a defensive re-allocation because some
  framework version misbehaved, put the framework version check *in the code*, not in a comment.
- **Per-call resource acquisition inside a loop is the standard shape of on-device OOM.** Thirty
  `InferenceFunction` loads per image is not obviously wrong when you read it; it is obviously wrong
  when you graph the footprint. Which is the argument for §4.

---

## 4. Responding to pressure

Knowing your budget is half the job. The other half is what you do when you are approaching it —
and here there is one shipping implementation in the corpus worth studying in detail, because it
has all five of the pieces most apps have none of. Everything in this section is
**community-measured / community-implemented**, from `notes/repos/noema-ios.md` §10.5–10.9, a
multi-backend iOS/macOS/visionOS app shipping on the App Store.

### 4.1 A live pressure snapshot with thermals folded in

```swift prelude:guide-context
struct LiveMemoryPressureSnapshot: Equatable {
    let footprintBytes: Int64
    let availableBytes: Int64?
    let budgetBytes: Int64?
    let thermalState: ProcessInfo.ThermalState
    let sampledAt: Date

    static func current(info: DeviceRAMInfo = .current()) -> Self
}

enum MemoryPressureLevel { case comfortable, elevated, high, critical }

var pressure: MemoryPressureLevel {
    // Thermals dominate: a hot device is a constrained device regardless of free bytes.
    if thermalState == .critical { return .critical }
    if thermalState == .serious  { return .high }

    // Absolute headroom next — these are hard floors, not proportions.
    if let availableBytes {
        if availableBytes <  256 * 1_048_576 { return .critical }
        if availableBytes <  512 * 1_048_576 { return .high }
        if availableBytes < 1024 * 1_048_576 { return .elevated }
    }

    // Then proportional: footprint / conservativeBudget.
    switch budgetProgress {
    case 0..<0.70:    return .comfortable
    case 0.70..<0.88: return .elevated
    case 0.88..<0.98: return .high
    default:          return .critical
    }
}
```

✅ **VERIFIED** as structure, thresholds and case names (`notes/repos/noema-ios.md` §10.5). Sampled
by a `Timer` at **1 Hz** (`sampleInterval: TimeInterval = 1.0`).

🟡 **RECONSTRUCTED** — the `* 1_048_576` multiplications are ours; the notes record the thresholds
as 256 MiB / 512 MiB / 1024 MiB. `ProcessInfo.ThermalState` cases exercised anywhere in this corpus
are **`.nominal`**, **`.serious`** and **`.critical`**; the enum is older than any of this and may
have more cases, but this guide does not assert cases it has not seen used.

Three design decisions in that snippet are worth copying verbatim:

- **Thermal state is checked first and can force `.critical` on its own.** A hot device that has
  plenty of free memory is still a device you should not start a big load on.
- **Absolute floors come before proportional ones.** 256 MiB of headroom is dangerous on any device,
  regardless of what fraction of a nominal budget you have consumed.
- **The snapshot is a value type with a timestamp.** You will want to diff two of them (§4.4).

### 4.2 A hysteretic governor, not a threshold

Threshold-triggered pressure handling oscillates: you free memory, the level improves, you reload,
the level degrades, and you have built a metronome. The fix is hysteresis.

```swift illustrative
actor OverfitMemoryGovernor {
    static let warnThreshold      = 0.12
    static let pressureThreshold  = 0.08
    static let criticalThreshold  = 0.05
    static let emergencyThreshold = 0.03
    static let recoveryFactor     = 1.5   // re-arm only after headroom > threshold × 1.5

    init(availableMemory: @escaping @Sendable () -> UInt64,
         footprint:       @escaping @Sendable () -> UInt64,
         applyPressure:   @escaping @Sendable (Int32) -> Void,
         onCritical:      @escaping @Sendable () -> Void,
         onEmergency:     @escaping @Sendable () -> Void,
         pollIntervalNanoseconds: UInt64 = 250_000_000)   // 4 Hz

    static func live(onCritical:onEmergency:) -> OverfitMemoryGovernor
    func prepare(totalBudget: UInt64)   // arms without polling — tests drive pollOnce()
    func start(totalBudget: UInt64)
    func stop()
    func pollOnce()
}
```

✅ **VERIFIED** as signature and constants (`notes/repos/noema-ios.md` §10.6).

The mechanics: `fraction = available / totalBudget`, where
`totalBudget = os_proc_available_memory() + phys_footprint` **captured at session start** — i.e.
the reconstructed process limit from §1.3, frozen once so the denominator does not wander. Levels
**fire once** and re-arm only when headroom recovers above `threshold × 1.5`.

The four thresholds are *fractions of remaining headroom*, not fractions consumed: 12% / 8% / 5% /
3%. Note how tight the emergency band is. By the time you are at 3% headroom you have perhaps one
allocation left.

The wiring shows what "responding" means at each level:

```swift illustrative
onCritical: {
    LlamaServerBridge.pagedApplyPressure(3)   // cancel queued reads; generation CONTINUES
    NotificationCenter.default.post(name: .noemaOverfitMemoryCritical, object: nil)
},
onEmergency: {
    NotificationCenter.default.post(name: .noemaOverfitMemoryEmergency, object: nil)
    // "Crash prevention beats grace"
    LlamaServerBridge.stop()
}
```

The comment — ***"Crash prevention beats grace"*** — is the whole policy in three words. At
emergency level the app kills its own inference server rather than letting jetsam kill the app.
A stopped generation is a recoverable product state with a message you control. A `SIGKILL` is not.

There is also a **2-second watchdog** that ends the session if the server's port drops to `<= 0`,
and the governor is **deterministically unit-tested** (`OverfitMemoryGovernorTests.swift`) via the
injected closures and `pollOnce()`. That injectability is not incidental: a pressure governor you
cannot test is a pressure governor you will not trust enough to make aggressive.

### 4.3 Background unload policy

Backgrounding is when jetsam is most likely to reach you, because a suspended app with a
multi-gigabyte footprint is exactly what the kernel is looking for.

```swift prelude:guide-context
enum BackgroundModelUnloadPolicy {
    static let enabledKey = "backgroundUnloadLargeModelsEnabled"
    static let inactiveDelaySecondsKey = "backgroundUnloadInactiveDelaySeconds"
    static let defaultInactiveDelaySeconds: TimeInterval = 120
    static let largeWorkingSetThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024   // 2 GiB

    static func decision(for profile: Profile) -> Decision
}
```

The decision ladder, in order (✅ **VERIFIED**, `notes/repos/noema-ios.md` §10.7). **Keep** reasons
first — the app refuses to unload if any of these hold:

`"policy disabled"` · `"scene active"` · `"no active chat model"` · `"generation in progress"` ·
`"send in progress"` · `"routing in progress"` · `"no local runtime format"`

Then by backend format:

| Format | Decision |
|---|---|
| ExecuTorch, Core ML/ANE, Foundation Models, Core AI | `.keep("lightweight runtime kept ready")` |
| GGUF | unload, with fallback to a large-runtime path |
| MLX | unload, no large-runtime fallback |

with `threshold = max(2 GiB, memoryBudgetBytes / 3)` and
`delay = (sceneState == .inactive) ? inactiveDelaySeconds : 0`.

Two subtleties:

- **Not every backend is worth unloading.** The ANE/Core AI/AFM paths are kept resident because
  their reload cost is high (see the 194-second cold specialization in §9.7) and their footprint is
  comparatively modest. This is a *per-backend* policy, not a global one.
- **Re-evaluate, don't decide once.** The controller re-runs the policy **every 1 second** while a
  turn is still streaming, with the rationale: *"If backgrounding happened during
  routing/generation, the first policy pass intentionally keeps the model. Reevaluate until the
  turn finishes so a large GGUF does not remain resident for the entire suspension."*

### 4.4 Verify the unload actually happened

This is the piece almost nobody builds, and it is the one that turns "we call `unload()`" into
"we know `unload()` works".

```swift prelude:guide-context
enum ModelUnloadVerifier {
    static let defaultRecoveryThresholdBytes: Int64 = 32 * 1024 * 1024   // 32 MiB

    static func evaluate(before: LiveMemoryPressureSnapshot,
                         after: LiveMemoryPressureSnapshot,
                         recoveryThresholdBytes: Int64 = defaultRecoveryThresholdBytes)
        -> ModelUnloadMemoryVerificationResult
    // Status: .recovered (released ≥ 32 MiB) | .unchanged | .increased | .unavailable
}
```

✅ **VERIFIED** (`notes/repos/noema-ios.md` §10.8). The calling sequence matters as much as the
comparison:

1. Snapshot memory.
2. Detach the client **on the main actor**.
3. `await` teardown **off** the main actor.
4. **Sleep 500 ms** — deallocation is not synchronous with the last release; Metal buffers and
   mapped regions come back on their own schedule.
5. Re-sample and log:
   `[ModelUnloadVerification] status=… before=… after=… released=…`

Note `.increased` as an explicit status. An unload that *raises* your footprint is a real outcome
— teardown allocates, caches get flushed into new buffers, an autorelease pool has not drained —
and if you do not have a name for it you will report it as `.unchanged` and never investigate.

### 4.5 The race you will hit

```swift illustrative
func unloadIfIdle(reason: String)
// Performs the idle check AND the client detachment in ONE MainActor.run transaction,
// guarded by an `idleUnloadGeneration: UUID?`.
```

> "Memory/background policy must not race a send between an idle check and client detachment."

✅ **VERIFIED** (`notes/repos/noema-ios.md` §10.8). This is the bug you will write: the policy
checks "is the app idle?", the answer is yes, and between that check and the actual detach the user
sends a message. Now you have unloaded a model that is mid-generation, and depending on the backend
that is anything from a dropped turn to a crash inside a runtime that no longer has weights.

The fix is not a lock around the unload. It is doing the **check and the detach in a single
transaction**, plus a generation token so a stale policy pass cannot act on a decision that has
been superseded. The blockers it reports are worth reproducing as a list, because each one is a
race someone found: `task-cancelled`, `unload-in-progress`, `streaming`, `send-in-flight`,
`routing`, `no-resident-client`.

### 4.6 What to wire up, minimally

If you take nothing else from this section, take this ordering. In increasing order of effort and
decreasing order of value-per-hour:

1. **Sample `phys_footprint` and `os_proc_available_memory()` at 1 Hz while a model is loaded, and
   log the peak.** Ten lines. It converts every future mystery crash into a data point.
2. **Refuse to load a model that fails a two-gate check** (§2.6), and give the user a real message
   rather than letting the load proceed and hoping.
3. **Unload on background** with a per-backend policy and a re-evaluation loop for in-flight turns.
4. **Verify the unload** with a before/after snapshot and a 500 ms settle.
5. **Add a hysteretic governor** with a stop-generation emergency level.

---

## 5. MLX-specific memory

MLX gives you three distinct dials, and they are frequently confused with one another:

- **The buffer cache limit** — how many bytes MLX keeps in its Metal buffer-reuse cache. Not your
  data; recycled allocations.
- **The memory limit** — a soft ceiling on MLX's own working set, seeded from the device's
  recommended working-set size.
- **Wired memory** — pages MLX asks Metal to keep resident, so that inference does not fault
  weights back in mid-token.

### 5.1 ⚠️ Two spellings, and you must check which one your version has

> 🔴 **GAP — `MLX.GPU.set(cacheLimit:)` versus `Memory.cacheLimit`.**
>
> The corpus contains **two** attested spellings for the buffer-cache dial in MLX Swift, from two
> different repositories, both current in 2026:
>
> - ✅ **VERIFIED** — `MLX.GPU.set(cacheLimit:)`, used in a **shipping App Store app** against
>   `mlx-swift` branch `main` (`notes/repos/noema-ios.md` §8.1).
> - ✅ **VERIFIED** — `Memory.cacheLimit` / `Memory.memoryLimit` / `Memory.snapshot()`, used
>   throughout **`mlx-swift-examples`**, whose research note states flatly: *"the old idiom
>   `MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)` **does not appear anywhere in this repo**. It has
>   been replaced by a `Memory` enum/namespace in the `MLX` module."*
>   (`notes/repos/mlx-swift-examples.md` §4.)
>
> **What is unknown:** whether `GPU.set(cacheLimit:)` still exists as a deprecated alias, at which
> mlx-swift version the `Memory` namespace landed, and whether `Memory` is an `enum`, `struct` or
> `actor`. The `mlx-swift-examples` note flags the last two as open questions itself.
>
> **What would resolve it:** `grep -rn 'cacheLimit' Sources/MLX/` in the exact `mlx-swift` revision
> your project resolves, or an `swift build` against both spellings.
>
> **SAFE DEFAULT:** write the dial once, behind your own tiny shim, and set the shim's body from
> whichever spelling compiles against your pinned revision. Do not scatter either spelling through
> your codebase; you will be changing it.
>
> ```swift
> // MemoryDial.swift — one place to change when the MLX spelling moves.
> import MLX
>
> enum MemoryDial {
>     static func setCacheLimit(_ bytes: Int) {
>         Memory.cacheLimit = bytes            // mlx-swift-examples spelling
>         // MLX.GPU.set(cacheLimit: bytes)    // shipping-app spelling; swap if the above fails
>     }
> }
> ```
>
> Both spellings are attested; neither is invented; and any guide that presents only one of them is
> hiding a compile error from you.

### 5.2 The verified `Memory` surface

From `mlx-swift-examples`, every symbol below with a cited call site
(✅ **VERIFIED**, `notes/repos/mlx-swift-examples.md` §4):

| Symbol | Type | Seen at |
|---|---|---|
| `Memory.cacheLimit` | settable `Int` (bytes) | `LLMBasicApp.swift:12`, `MLXService.swift:56`, `LLMEvaluator.swift:105` |
| `Memory.memoryLimit` | settable **and readable** `Int` (bytes) | `StableDiffusionExample/ContentView.swift:141` reads it |
| `Memory.snapshot()` | `-> Memory.Snapshot` | `DeviceStat.swift:10,12,26` |
| `Memory.Snapshot.activeMemory` | `Int` | `LLMEval/Views/ContentView.swift:58` |
| `Memory.Snapshot.cacheMemory` | `Int` | `…:59` |
| `Memory.Snapshot.peakMemory` | `Int` | `…:60` |
| `Memory.Snapshot.description` | `String` | `MemoryArguments.reportMemoryStatistics()` |
| `Memory.Snapshot.delta(_:)` | `-> Memory.Snapshot` | `DeviceStat.swift:26` |

The canonical app idiom is the entire `LLMBasicApp.swift` file:

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

✅ **VERIFIED** — this is the complete file, and its README explains the two settings verbatim:

> - "LLM models are large so this uses the Increased Memory Limit entitlement on iOS to allow …
>   increased memory limits for devices that have more memory"
> - "`Memory.cacheLimit = 20 * 1024 * 1024` is used to limit the buffer cache size"

Observed limits across the sample apps (✅ **VERIFIED**, same source):

| App | cacheLimit | memoryLimit |
|---|---|---|
| LLMBasic, LLMEval, MLXChatExample | 20 MB | — |
| LoRATrainingExample | 32 MB | — |
| StableDiffusionExample (low-memory device) | **1 MB** | **3 GB** |
| StableDiffusionExample (normal) | 256 MB | — |
| `llm-tool` / `image-tool` / `embedder-tool` | `--cache-size` MB (image-tool default 1024) | `--memory-size` MB |

#### The "detect a small device" pattern

```swift illustrative
// Applications/StableDiffusionExample/ContentView.swift:133-151
public nonisolated let conserveMemory: Bool

init() {
    let defaultParameters = configuration.defaultParameters()
    self.canShowProgress = defaultParameters.steps > 4
    self.canUseNegativeText = defaultParameters.cfgWeight > 1

    // this will be true e.g. if the computer has 8G of memory or less
    self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024

    if conserveMemory {
        print("conserving memory")
        loadConfiguration.quantize = true
        Memory.cacheLimit  = 1 * 1024 * 1024
        Memory.memoryLimit = 3 * 1024 * 1024 * 1024
    } else {
        Memory.cacheLimit = 256 * 1024 * 1024
    }
}
```

✅ **VERIFIED** (Apple sample code via `notes/repos/mlx-swift-examples.md` §4.2). The trick is in
the first assignment: **read `Memory.memoryLimit` before you write it.** MLX seeds it from the
device's recommended Metal working-set size, so reading it is a free, accurate device-capability
probe — better than a model-identifier table, and it works on hardware that shipped after your app.

Note also that the low-memory branch does not just shrink buffers; it **changes the model
configuration** (`loadConfiguration.quantize = true`). Memory policy that only tunes allocator
knobs will lose to memory policy that is allowed to pick a different artifact.

### 5.3 The cache limit is process-wide — refcount it

This is the sharpest practical gotcha in the section, and it comes from the shipping app rather
than the samples (✅ **VERIFIED**, `notes/repos/noema-ios.md` §8.1):

```swift illustrative
/// Max bytes MLX keeps in its Metal buffer-reuse cache. The old flat 20 MB starved large
/// models on Mac — every op had to re-allocate/free big Metal buffers instead of reusing
/// them, throttling throughput badly. Scale with available RAM: generous on Mac (ample
/// unified memory), modest on the memory-constrained (jetsam-prone) mobile platforms.
static var gpuCacheLimitBytes: Int {
    let ram = Int(ProcessInfo.processInfo.physicalMemory)
    #if os(macOS)
    return min(1024 * 1024 * 1024, max(256 * 1024 * 1024, ram / 16))
    #else
    return min( 128 * 1024 * 1024, max( 32 * 1024 * 1024, ram / 32))
    #endif
}

private static var count = 0
static func retainGPUCache() {
    count += 1
    MLX.GPU.set(cacheLimit: gpuCacheLimitBytes)
}
static func releaseGPUCache() {
    count -= 1
    if count == 0 { MLX.GPU.set(cacheLimit: 0) } else { reassert() }
}
```

The rationale, verbatim:

> "The Metal buffer-cache limit is a single **PROCESS-WIDE** value, but on macOS two MLX models can
> be resident at once (the chat model + Autopilot's local escalation model). A naive `set(0)` in
> one client's `unload()` would starve the other."

Three things here:

1. **The flat 20 MB from the sample apps is a *sample app* number.** It is correct for one small
   model on a phone. On a Mac running a large model it *throttles throughput badly* by defeating
   buffer reuse. Scale it: `ram / 16` on macOS clamped to [256 MB, 1 GB]; `ram / 32` on iOS clamped
   to [32 MB, 128 MB].
2. **Refcount it if two models can coexist.** This is a process-global, and "unload the model I own"
   is not the same as "nobody is using MLX".
3. **`ProcessInfo.processInfo.physicalMemory` is the right input here** — not the process budget.
   The buffer cache is a throughput/footprint tradeoff, and it scales with the machine.

### 5.4 Wired memory

`MLXLMCommon` supplies **policies**; the manager, ticket and policy protocol themselves come from
`mlx-swift` (✅ **VERIFIED**, `notes/repos/mlx-swift-lm.md` §17, read from
`Libraries/MLXLMCommon/WiredMemoryPolicies.swift`):

| Policy | Limit formula | Admission |
|---|---|---|
| `WiredSumPolicy(cap: Int? = nil)` | `clamp(baseline + sum(activeSizes))` | denies if projected > cap |
| `WiredMaxPolicy()` | `max(baseline, max(activeSizes))` | default |
| `WiredFixedPolicy(limit: Int)` | `bytes` while any ticket is active | default |
| `WiredBudgetPolicy(baseBytes: Int, cap: Int? = nil, id: UUID = UUID())` | `clamp(baseline + baseBytes + sum(activeSizes))` | denies if projected > cap |

`clamp` falls back to **`GPU.maxRecommendedWorkingSetBytes()`** when no cap is set and Metal is
available. Usage, from `Documentation.docc/using-model.md:135-145`:

```swift prelude:guide-context
let policy = WiredSumPolicy()
let ticket = policy.ticket(size: estimatedBytes)
let stream = try MLXLMCommon.generate(
    input: input,
    parameters: generateParameters,
    context: context,
    wiredMemoryTicket: ticket)
```

✅ **VERIFIED**. And the measurement helper, which is how you get `estimatedBytes` honestly:

```swift illustrative
public struct WiredMemoryMeasurement: Sendable {
    public let weightBytes, kvBytes, workspaceBytes, peakActiveBytes,
               tokenCount, prefillStepSize: Int
    public var totalBytes: Int
}

public enum WiredMemoryUtils {
    public static func tune(…)   // 3 overloads: tokens, LMInput, UserInput
}
```

Note the breakdown fields: `weightBytes`, `kvBytes`, `workspaceBytes`, `peakActiveBytes`. That is
§2.1's sum, computed for you, on your actual model. Use it instead of a spreadsheet.

Measuring weight bytes directly is three lines (`wired-memory.md:21-28`):

```swift prelude:guide-context
let context = try await LLMModelFactory.shared.load(configuration: config)
let weightBytes = context.model.parameters()
    .flattened()
    .reduce(0) { $0 + $1.1.nbytes }
```

And the documented deltas are a useful sanity check on how close these three numbers run
(community/first-party measurements quoted in `wired-memory.md:58-61`):

| Model | `nbytes` | tensor files | active after load |
|---|---:|---:|---:|
| Qwen3-4B-Sky-High-Hermes-4bit | 2,262,535,712 | 2,262,637,937 | 2,264,337,376 |
| Qwen3-Next-80B-A3B-Instruct-MLX-4bit | 44,844,060,160 | 44,844,286,608 | 44,844,101,616 |

**Weights land within ~0.1% of the file size.** That is the reassuring part. It is also exactly why
weights are the *easy* term and every other term in §2.1 is where the surprises live.

Finally, for CPU or unsupported-Metal contexts:

```swift prelude:guide-context
await WiredMemoryManager.shared.updateConfiguration { configuration in
    configuration.policyOnlyWhenUnsupported = true
}
```

✅ **VERIFIED** — policy-only mode, so admission control still runs even where wiring is a no-op.

### 5.5 Quantized KV is not automatically smaller in peak

The MLX parameter surface for KV quantization, as mapped by a shipping app
(✅ **VERIFIED**, `notes/repos/noema-ios.md` §8.5):

```swift prelude:guide-context
parameters.maxKVSize            = settings.resolvedMLXKVCacheLimit
parameters.kvBits               = settings.mlxKVCacheQuantization.bits   // nil for .fullPrecision
parameters.kvGroupSize          = settings.resolvedMLXKVCacheGroupSize
parameters.quantizedKVStart     = settings.resolvedMLXKVCacheQuantizationStart
parameters.prefillStepSize      = settings.resolvedMLXPrefillStepSize
```

with `MLXKVCacheQuantization` covering `.fullPrecision(nil)`, `.eightBit(8)`, `.sixBit`,
`.fiveBit`, `.fourBit`, `.threeBit`, `.twoBit`.

`quantizedKVStart` is the one to notice: quantization begins after a threshold, so the first N
tokens are full precision. That is a quality decision with a memory consequence, and it means the
steady-state KV size is not `tokens × bits/8 × …` but a piecewise function. The counter-intuitive
part — that quantized KV can *increase* peak memory during the conversion step — is covered in
[Part 12 guide 4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/04-mlx-lm-cli-generation-and-caching.md).

For everything else about running MLX inside a Swift app — package setup, the 3.x redesign,
`ModelContainer`, Swift 6 strict concurrency, media input — see
[Part 13 guide 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).

---

## 6. Another allocator can starve you

Unified memory is the reason Apple silicon is good at this. It is also the reason your careful
budget can be irrelevant.

On a discrete-GPU machine, VRAM is a separate pool and one framework's appetite for it is visible
and bounded. On Apple silicon, the GPU, the ANE, the CPU, the window server and every framework
you link share **one** pool. Your model's weights, another library's tensor allocator, the OS
compositor and the page cache are all competing for the same bytes. A budget computed against
"total RAM" or even against `os_proc_available_memory()` at launch is a snapshot of a shared
resource.

### 6.1 The forum report: ~40 GiB of "other allocations"

⚠️ **Community-reported, status unknown.** Apple Developer Forums thread **824753**:

> "MPS backend reports ~**40 GiB 'other allocations'** on a **48 GB M5 Pro** under **macOS 26.4.1**,
> blocking large tensor operations (PyTorch)."

(`notes/forums/forum-pain-points.md` §2.11, from a capture of the General topic. The thread title
is what is recorded; **no Apple-staff answer is recorded in this corpus**, and the resolution
status is unknown as of 2026-07-27.)

Do not over-read this. It is one thread, one machine, one OS point release, one framework's
allocator, and we do not know whether it is a leak, an accounting artifact, a driver bug, or user
error. What makes it worth a section is not the specific number. It is that **the failure mode it
describes is structural**, and the corpus contains several independent instances of the same shape:

| Instance | What ran out | Where |
|---|---|---|
| MPS reports ~40 GiB "other allocations" on 48 GB, blocking large tensor ops | someone else's allocator | forum 824753, macOS 26.4.1, M5 Pro |
| `mlx_lm.server` aborts: `Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)` after the **prompt cache grew to 23.35 GB / 26.28 GB** | your own cache, unbounded | mlx-lm#1390, 48 GB, macOS 27.0 (26A5353q), mlx-lm 0.31.3 |
| Two images totalling 8140 pads requested a **single 33.9 GB Metal buffer**, past `maxBufferLength` on a 48 GB M4 Pro | one allocation, quadratic in inputs | `notes/repos/issues-mlx-stack.md` §, VLM attention mask |
| Use-after-free under memory pressure: buffer-cache trim freed an `MTLBuffer` still used by an in-flight command buffer (`kIOGPUCommandBufferCallbackErrorInvalidResource`) | the allocator's own reclaim path | mlx#3689 (CLOSED) |
| A dtype promotion in `segsum` wasted **~960 MB on Qwen3.5-35B at 2k context, ~24 GB on Nemotron-30B** — *"one line fix"* | an accidental fp32 scalar | mlx-swift-lm #229 |

All community-reported. All the same underlying fact: **on unified memory, the thing that kills
you is frequently not your model.**

### 6.2 What to do about it

Five defences, roughly in order of value:

1. **Never size "as big as fits".** This is worth stating as a law because the counter-evidence is
   startling. A community study of MoE expert offload measured decode throughput against
   materialized-cache size on an M5 Max with 128 GB and found the curve is **a peak, not a
   monotone**: hit rate rose steadily from 0.24 to 0.60 as the cache grew from 20 GB to 75 GB, but
   **decode tok/s peaked at ~30–35 GB and then collapsed** — 60 GB → 0.34, 75 GB → 0.17, and
   *"shrinking 60 → 35 GB is +65% decode."* The floor datum is the punchline: at a 10 GB cache the
   hit rate was **0%** and decode still beat the 60 GB cache, because *"the OS page cache alone
   outruns a materialized cache big enough to starve it."*
   (Community-measured, `notes/repos/issues-mlx-stack.md` §8.3.) The generalisation the same source
   draws — *"on Apple the effective kernel page-cache reserve is tens of GB"* — is the practical
   rule: **leave the OS room to do its job.** Apple's own macOS guidance, *"leave at least 6 GB of
   RAM headroom"*, is the conservative version of the same advice.
2. **Re-read your budget, don't cache it.** `os_proc_available_memory()` is cheap. Sample it before
   every load and at 1 Hz during, as §4.1 does. A budget captured at launch is a lie by the time a
   second framework has initialised.
3. **Bound every cache you own.** The `mlx_lm.server` row above is a prompt cache with no ceiling.
   Noema caps llama.cpp's prompt cache explicitly, with the reason in the comment:

   ```swift compile:27
   // "llama.cpp defaults to an 8 GiB cache-ram ceiling with 32 checkpoints per slot,
   //  which is a latent out-of-memory risk on iOS."
   #if os(macOS)
   let defaultCacheRamMiB: Int32 = 4096 ; let defaultCtxCheckpoints: Int32 = 8
   #else
   let defaultCacheRamMiB: Int32 = 1024 ; let defaultCtxCheckpoints: Int32 = 4
   #endif
   ```

   ✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §7). An 8 GiB default cache
   ceiling is fine on a workstation and is a jetsam guarantee on a phone. **Audit the defaults of
   every runtime you embed for numbers that were chosen on a Mac.**
4. **Watch for quadratic allocations in input size.** The 33.9 GB single-buffer case was a VLM
   merging all images into one attention sequence, so memory grew with **(Σ Lᵢ)² instead of Σ Lᵢ²**.
   Any place where you concatenate variable-length inputs before attention is a candidate. The
   symptom is not gradual pressure; it is one allocation past `maxBufferLength`.
5. **Do not assume another process's memory is your memory.** Conversely, do not assume it is not.
   `SystemLanguageModel` runs out of process (§1.4) so its footprint is not charged to you — but it
   is charged to the *device*, and the device is what jetsam is defending.

> ⚠️ **SILENT FAILURE — an allocator's reclaim path can free memory you are still using.**
> mlx#3689 (community-reported, now closed) documented a use-after-free where the buffer cache's
> trim, running under memory pressure, freed an `MTLBuffer` that an in-flight command buffer still
> referenced — surfacing as `kIOGPUCommandBufferCallbackErrorInvalidResource`. The relevant property
> is that **this only happens under pressure**, so it will not reproduce on your uncontended desk
> machine and will show up as a nondeterministic crash in the field. A related Metal-level race
> (`mlx#3461` / PR #3462) was validated at **0/10 → 10/10 success** on an M5 Max at batch 17 after
> the fix, at ~2.4% throughput cost. If you are pinning MLX revisions, pin forward past these.

---

## 7. Thermals and DVFS

Almost every published on-device LLM benchmark reports a **burst** number: run the model once,
cold, on an idle device, report tok/s. That number is real. It is also, on a phone, close to
useless for predicting what a user experiences — and, worse, it is not even a stable *burst*
number, because the GPU's clock has not finished ramping.

This section has two distinct effects in it, and conflating them is the standard error:

- **DVFS ramp** — the GPU takes time to reach its operating clock. A short workload can *finish
  before the clock arrives*. This makes cold measurements **too low**.
- **Thermal throttling** — sustained load heats the SoC and the OS sheds clock. This makes long
  measurements **lower over time**.

They push in the same direction over a long run and in opposite directions over a short one, which
is exactly why "just run it a few times and take the median" does not fix it.

### 7.1 The DVFS finding

This is the sharpest benchmarking-hygiene result in the corpus, and it comes from **17
single-variable runs** on one device.

**Community-measured**, iPhone 17 Pro (A19 Pro), iOS 27 beta, hand-written Metal decode/prefill
kernels on Gemma-4 E2B; `notes/repos/john-rocky-models.md` §9.1 citing `custom-metal-kernels.md:71-81`:

| Launch condition | Prefill tok/s |
|---|---:|
| p347 prefill launched from **device idle** | **66–68** — *finishes before the GPU clock ramps* |
| p~1000 prefill (ramps **mid-run**) | **87** |
| Run launched **right after sustained UI interaction** | **95–102** |

> "Thermal, Low Power Mode, cable vs battery, screen state and brightness were **all eliminated as
> causes**. **Quote the pair '≈87 tok/s @p1k / 66–68 @p347 cold-start' — never a pre-ramped burst
> number alone.**"

Read the spread: **66 to 102 tok/s is a ~1.5× swing on one device, one artifact, one afternoon,
purely from what the GPU clock was doing when the work arrived.** A cold first measurement
understates the steady-state figure by roughly 40%.

**An honest caveat about this table, stated because the source states it.** The three rows are not
the same prompt length: the cold row is p347, the ramping row is p~1000. Prompt length and ramp
condition are confounded in that pair, which is *why* the source's instruction is to quote the pair
together rather than either number alone. The 95–102 row is the cleanest evidence for the ramp
mechanism specifically, because it differs from the others only in what the device was doing
immediately before.

The same measurement produced a diagnostic that is genuinely useful in the field:

> "Byte-bound decode barely moves between regimes (**51–52 @ctx≈380**), which is also the **thermal
> tell**: **decode sliding below ~51 means the device is genuinely warm.**"

That is a two-for-one: **decode rate is a poor throughput headline and an excellent thermometer.**
Prefill is compute-bound and therefore clock-sensitive; decode at small context is bandwidth-bound
and therefore clock-*insensitive* — until the device is hot enough that the memory system slows too.
Instrument both, and use the decode number as your thermal canary.

### 7.2 A warm-up protocol you can actually run

The corollary of §7.1 is that a benchmark harness needs a defined warm-up, and "run it twice" is
not one. The protocol below is assembled from what the sources actually did.

```swift prelude:guide-context
/// Warm-up protocol for on-device throughput measurement.
///
/// Rationale, all community-measured on A19-class hardware:
///  - a short workload from device idle can complete before the GPU clock ramps (§7.1)
///  - the FIRST EVER run of a bundle includes on-device specialization (§9.7) — never average it in
///  - back-to-back runs droop 5–10%, so "settled" means trial-1 of a settled run, not trial-N
struct WarmupProtocol {
    /// 1. Establish thermal baseline. Refuse to measure if the device is already warm.
    static func gate() throws {
        let env = ProcessInfo.processInfo
        guard env.thermalState == .nominal else {
            throw BenchError.thermalGate(env.thermalState)
        }
        guard env.isLowPowerModeEnabled == false else {
            throw BenchError.lowPowerMode
        }
    }

    /// 2. Ramp the clock with real work, then discard it.
    ///    A prefill of the SAME shape you will measure, discarded.
    static func ramp(_ run: () async throws -> Void) async throws {
        try await run()   // discarded: this is the ramp, and possibly the specialization
    }

    /// 3. Measure trial-1 of the settled run, and report cold and warm SEPARATELY.
}
```

🟡 **RECONSTRUCTED** — `ProcessInfo.processInfo.isLowPowerModeEnabled` is the property name inferred
from a shipping app's `Environment { thermalState: ProcessInfo.ThermalState; lowPowerMode: Bool;
… static var current }` (`notes/repos/noema-ios.md` §10.9); the corpus records the *concept* and the
struct field, not the literal `ProcessInfo` spelling. `ProcessInfo.processInfo.thermalState` and the
`.nominal` / `.serious` / `.critical` cases are ✅ **VERIFIED** across three independent sources
(Noema's policy, Noema's pressure meter, and a machine-generated benchmark blob that records
`"thermal_state_before": "nominal"`).

Two rules from the sources that the code above encodes:

- **Gate on `.nominal`, and publish your exclusions.** A community benchmark protocol
  (`pb-random-v1`) *"excludes blobs with **Low Power Mode on** or a **serious/critical thermal
  state** before the run … **and the exclusion count is published**."* (Community protocol,
  `notes/repos/john-rocky-models.md` §3.3.) Publishing the exclusion count is what stops the filter
  from becoming a way to discard inconvenient runs.
- **"20 minutes cold" is not a magic wand.** The same author tested it: *"back-to-back device runs
  droop 5–10%; **'20-min-cold' does NOT measure faster than mid-session (tested)** — day noise is
  ±1.4 tok/s. Fresh = trial-1 of a settled run, and **cross-config claims need interleaved A/B, not
  different-day numbers.**"* (Community-measured, `gemma4-raw-metal-a19-levers.md:52-62`.)

That last clause is the one people violate constantly. **If you are comparing two configurations,
interleave them in one session.** A different-day number on a ±15%-drift machine, as another source
in the same corpus puts it, *"will confirm anything."*

### 7.3 Sustained throughput: the GPU/ANE inversion

Now the other effect. Run continuously and the ranking changes.

**Community-measured**, Gemma 4 E2B on iPhone 17 Pro; method stated as *"600 s continuous
generation, cold (`nominal`) start, unplugged, tg128; decode rate from a rolling window"*;
`notes/web/community-blogs.md` §2.6:

| Runtime | Burst tok/s | Sustained (10 min) | Retained |
|---|---:|---:|---:|
| **CoreML / ANE** | 33 | **22** | **67%** |
| MLX / GPU | 48 | 18 | 38% |
| LiteRT-LM / GPU | 56 | 27 | 48% |

> "Run the same model **continuously** and it flips: the GPU runtimes (MLX, LiteRT-LM) heat up and
> shed **~50–60% of their throughput** under sustained load, while the **ANE barely moves** (retains
> ~65%). MLX crosses the 50%-lost line within ~60 s… The ANE draws ~half the package power… so it
> heats slowly and the SoC doesn't throttle it."

> "Two **independent** GPU runtimes collapsing the same way is a **GPU-thermal property of the
> phone, not a runtime quirk**. MLX ends up *below* the ANE… **The GPU wins the sprint; the ANE
> wins the marathon** — and it frees the GPU for the rest of the app."

Retention across a wider set of arms from the same project, same model and device:

| Arm | Retained after 600 s |
|---|---:|
| LiteRT | 76% |
| MLX-OptiQ | 67% |
| MLX-PTQ | 64% |
| Cactus | 57% |
| **Core AI** | **56%** |
| llama.cpp | 54% |

The guide implication the source draws is exactly right and worth restating: a headline like
"Core AI 181 tok/s" is a **burst** number, and for an always-on feature that path will shed ~44% of
it. If your feature is a one-shot summarisation, burst is the number that matters. If it is live
transcription, a coding agent, or anything that runs for minutes, **sustained is the only number
that matters and it may reorder your backend choice.**

A separate, blunter data point on the same axis: a vision model measured at **25 ms per inference**
on a cool iPhone measured **58–103 ms** once thermally saturated — the source's framing is *"a day
of device use silently degrades a **25 ms** model to **58–103 ms** (thermal saturation, not your
app)."* That is a **2.3–4.1× measurement swing from thermals alone**. (Community-measured,
`notes/repos/john-rocky-models.md` citing `conversion-guide.md:180-182`.)

### 7.4 Thermal *state* is a coarse instrument

Do not treat `ProcessInfo.ThermalState` as a sufficient control.

A machine-generated benchmark blob from the `pb-random-v1` protocol — a real submission, not a
reconstruction — recorded four consecutive runs on an iPhone 17 Pro (`iPhone18,1`, iOS 27.0 build
`24A5355q`, 12.3 GB RAM) with **`thermal_state_before` and `thermal_state_after` both `nominal`
throughout** (community-measured, `notes/repos/john-rocky-models.md` §11.2):

| Kind | Prefill tok/s | Decode tok/s |
|---|---:|---:|
| cold | **31.10** | **70.67** |
| warm | 70.38 | 68.72 |
| warm | 69.70 | 68.41 |
| warm | 64.45 | 66.16 |

Two readings:

1. **Cold prefill is 31.1 versus ~70 warm — a 2.3× first-run penalty entirely separate from the
   3.4 s load time.** This is the DVFS/specialization effect of §7.1 and §9.7 showing up in a real
   submitted result.
2. **Decode drifts 70.7 → 66.2 across four consecutive runs while thermal state never leaves
   `nominal`** — a ~6% droop with no state change. Which corroborates the independent claim from
   §7.1's author that thermal *state* is coarse: the device was measurably degrading and the API
   said nothing had changed.

**Conclusion: gate on thermal state, but do not trust it as a control variable.** Record it,
publish it, and additionally record run index, wall-clock time since session start, and your decode
canary (§7.1) so that a droop inside `nominal` is visible in your data rather than invisible in
your average.

### 7.5 Thermal state as an input to your app, not just your benchmark

A shipping app treats thermals as a first-class scheduling input. Noema's `GenerationPowerPolicy`
(✅ **VERIFIED**, community source, `notes/repos/noema-ios.md` §10.9):

```swift illustrative
struct Environment {
    let thermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool
    let activeProcessorCount: Int
    static var current: Self { … }
}

enum Reason: String { case lowPowerMode, seriousThermal, criticalThermal }

static func adjustedSettings(_ settings: ModelSettings,
                             format: ModelFormat,
                             environment: Environment = .current)
    -> GenerationPowerPolicyDecision
```

The policy, verbatim in behaviour — note that it **only adjusts `.gguf` / `.mlx` / `.et`**, the
CPU/GPU-heavy backends:

| Condition | threadLimit | keepInMemory | disableWarmup |
|---|---|---|---|
| Low Power Mode | `cores / 2` | `false` | — |
| `.serious` thermal | `cores / 2` | `false` | **`true`** |
| `.critical` thermal | `cores / 3` | `false` | **`true`** |

And a separate gate for the storage-heavy paged path:

```swift illustrative
static func pagedLaunchGate(environment: Environment) -> OverfitPagedLaunchGate
// .critical thermal            -> .blocked(.criticalThermal)
// .serious thermal OR lowPower -> .allowedReduced(reasons:)   // shrink IO fan-out and context
// else                         -> .allowed
```

with the rationale: *"Paged decode adds sustained storage and CPU traffic on top of inference, so
thermals gate it harder than a resident launch."*

Two further constants from the same file that belong in any inference app:

```swift illustrative
/// Leaves headroom for the system.
static var recommendedInferenceThreadCount: Int { max(1, activeProcessorCount - 2) }

/// "Hard ceiling for inference threads. Always leaves at least one core free for the UI"
static var maxInferenceThreadCount: Int { max(1, activeProcessorCount - 1) }
```

**Never use all the cores.** A model that generates 5% faster while the UI stutters is a worse
product, and on a thermally constrained device it is frequently not even faster.

#### What you cannot control

⚠️ There is **no NPU priority entitlement or API.** Apple staff, Developer Forums thread 833666
(✅ **VERIFIED**, Apple-staff answer, `notes/forums/forum-pain-points.md` §3.21). The developer
asked whether, given the `continued-processing.gpu` entitlement exists for background GPU work,
there is an equivalent for the Neural Engine so an app's model is not preempted by system-level
Apple Intelligence features. The answer:

> "The OS manages the requests for the on-device LLM automatically, based on the system conditions
> (like thermals). **There's no entitlement or API to influence this.**"

Design for it: assume your ANE work can be descheduled, do not build UX that requires a latency
guarantee you cannot obtain, and if you need predictable latency, the GPU path — which you can at
least reason about — may be the better product decision even where it is the slower one.

---

## 8. Energy

Throughput and energy are different questions with different answers. If you only measure one, you
will ship the wrong backend for a background or always-on feature.

### 8.1 The table where the winner loses

⚠️ **Read the attribution before the numbers.** This is **community-measured**, on **beta OSes**,
and — critically — **the raw data for this table is not present in the repository that cites it.**
The citing source names `litertlm-convert/reports/coreai-ane-gpu-parity-addendum.md`, which is
**not in that repository**, and the research note flags it as **UNVERIFIED at source**
(`notes/repos/john-rocky-models.md` §7.1). Treat these rows as a *directional* result from a
credible author, not as a citable measurement.

**iPhone 17 Pro, DeepSeek-R1-1.5B, matched 4-bit bytes** (ANE 0.97 GB / Core AI GPU 0.95 GB /
MLX 0.95 GB), cold short-chat, median of 3:

| Path | Decode tok/s | Energy (tokens per 1% battery) |
|---|---:|---:|
| **Core AI ANE** | **83.3** 🥇 | **6,144** 🥇 |
| Core AI GPU | 75.9 🥈 | 4,506 🥉 |
| MLX (mlx-swift, GPU) | 73.0 🥉 | 5,662 🥈 |

**The throughput silver medallist is the energy bronze medallist, and vice versa.** Core AI's GPU
path is second-fastest and *least* efficient; MLX's GPU path is slowest of the three and 26% more
efficient per token than the other GPU path. Ranking by tok/s and ranking by battery give you
different orders from the same three runs.

The author's own interpretation is more careful than the table, and worth carrying:

> "The ANE-vs-GPU delta **sign-flips across sibling models** → **throughput parity**, not an ANE
> speed win. And the ANE *energy* edge over MLX-GPU is only **~+8.5%** (it's +36% over CA's own GPU
> — **MLX's GPU path is energy-efficient**); the robust ANE win is **GPU exclusivity** (UI/rendering
> don't contend)."

So the defensible claims from this data are:

- **Throughput: parity.** Do not tell anyone the ANE is faster; the sign flips between models.
- **Energy: the ANE leads MLX by ~8.5%**, which is a real but modest margin, and leads the *other
  GPU path* by 36%, which says more about that path than about the hardware.
- **The durable ANE advantage is not a number in this table at all.** It is that ANE work does not
  contend with your UI for the GPU. For an app that renders while it infers, that is worth more
  than either column.

### 8.2 Low power ≠ low energy

The second energy table is better-sourced and contains the genuinely counter-intuitive result.

**Community-measured**, M4 Max, Gemma 4 E2B, sustained-512, whole-system package power via
`powermetrics`; `notes/web/community-blogs.md` §2.7:

| Runtime | Avg package power (W) | Energy / 512-token run (J) | **J / token** |
|---|---:|---:|---:|
| **apple-fm** (system model) | **7.6** | 67.4 | **0.11** 🥇 |
| mlx-swift (4-bit MLX) | 24.7 | 123.0 | 0.24 |
| llama.cpp (Q4_K_M, GGUF) | 24.5 | 126.3 | 0.25 |
| coreml-llm (INT4 palettized, ANE) | **12.7** | 244.9 | **0.48** ✗ |

> "**Energy ranking inverts the decode-tok/s ranking.** Apple FM is 2× more efficient per token than
> the GPU-backed runtimes despite producing tokens at ~half the rate. **CoreML/ANE has the lowest
> *instantaneous* power (12.7 W) but is the *worst* J/tok at 4× Apple FM, because the slower decode
> (32 tok/s) keeps the package powered up much longer.**"

**Read the CoreML/ANE row twice.** It draws the *least* instantaneous power of any GPU-or-ANE arm —
about half the GPU runtimes — and it is the **worst** energy consumer per token, by 2× over the
things drawing double its watts. The mechanism is arithmetic, not mystery:

```
J/token = package_watts / tokens_per_second
```

Halving the watts while thirding the throughput is a net loss. **Low power is not low energy, and
"the efficient one" is a claim about a ratio, not about a wattmeter reading.**

Note also that this table and §8.1's disagree about ANE energy, and they should: §8.1 is an iPhone
with a Core AI ANE bundle; §8.2 is a Mac with a Core ML INT4-palettized ANE model at 32 tok/s. The
compute unit is the same; the artifact, the runtime, the device and the throughput are not. **This
is why §9 insists on stating the build per row** — see §9.3.

For completeness, the same project's Mac Pareto on best-available builds (community-measured,
M4 Max, 2026-07-19, decode-window J/token, warm loads):

| Build | J/tok (decode) | W (decode) | tok/s |
|---|---:|---:|---:|
| MLX PTQ 4-bit | **0.090** 🥇 | 14.6 | **177.8** 🥇 |
| MLX QAT OptiQ | 0.106 | 14.6 | 149.5 |
| LiteRT wNa8o8 (WebGPU path) | 0.154 | 22.2 | 155.0 |
| llama.cpp Q4_K_M | 0.170 | 20.5 | 127.1 |
| Core AI own int4 (patched, S=1 window) | ~0.33 | 18.9 | 53 eff. |

> "**MLX owns the Mac energy Pareto** — fastest *and* most efficient, at the lowest package power."

Which is a useful reminder that the inversion is not a law. Sometimes one arm wins both. The point
is that you cannot know without measuring both, and **the two axes disagree often enough that
assuming they agree is a coin flip.**

### 8.3 Measuring energy without lying

Three practical approaches, in decreasing order of rigour:

1. **`powermetrics` on macOS.** Whole-system package power, sampled during a defined decode window.
   This is what the §8.2 table used, and its main weakness is stated in its own label: *whole-system*.
   Anything else running is in your number. Quiesce the machine, and report the idle baseline
   alongside the loaded figure so a reader can subtract.
2. **Tokens per 1% battery on iOS.** Cruder, unplugged, and the unit is device-specific — but it is
   the unit a *product decision* is actually made in, and it is measurable without any special
   tooling. Requirements: unplugged, screen brightness fixed, Low Power Mode off (and recorded),
   airplane mode if your workload does not need network, and a long enough run that quantisation of
   the battery percentage does not dominate. The §8.1 source used this unit.
3. **Wall-clock × a published power figure.** Do not. This is how "the ANE draws less power
   therefore uses less energy" gets published.

**Whatever you use, report the decode window separately from the load.** A 194-second cold
specialization (§9.7) inside your energy window will swamp the thing you are trying to measure, and
a warm-load-only figure will understate what the user's battery actually experiences on first run.
Report both, labelled — the same rule as §2.2's RSS-versus-footprint and §9.7's cold-versus-warm.

---

## 9. Honest benchmarking

Everything so far has been a reason why a number can be wrong. This section is the methodology that
makes a number defensible. It is assembled almost entirely from **documented measurement failures**
— cases where a careful person published or nearly published a wrong result and then wrote down why.

The organising principle is one sentence, from a community methodology document written after a
cross-runtime quality comparison collapsed:

> **"Inherited numbers are not measurements. If you cannot re-run it, do not cite it."**

(`notes/repos/john-rocky-models.md` §7.3, `cross-runtime-quality-benchmarking.md`.)

### 9.1 State the environment. Every time.

The minimum disclosure set, derived from what the sources in this corpus record and from what they
say they wish they had recorded:

| Field | Why |
|---|---|
| **Device identifier** (`iPhone18,1`, not "iPhone 17 Pro") | Marketing names collide across configurations; §1.4's storage-tier RAM bump is invisible in the marketing name |
| **OS build**, not just version (`iOS 27.0 (24A5355q)`) | Betas move. §9.5 is a 2.2× effect from a build difference |
| **Xcode version and SDK** | The artifact depends on the toolchain, §9.5 |
| **Build configuration** | §9.6 — a 3× effect, measured |
| **Thermal state before and after**, and Low Power Mode | §7.4 |
| **Battery level and charging state** | Charging changes thermal behaviour and clock policy |
| **Free disk and available memory** | §1, and because a mid-run jetsam is a result |
| **Date** | So a reader can tell how stale it is |
| **The exact artifact** — repo, revision, file, size | §9.3 is worth 84 points on its own |
| **The protocol** — prompt tokens, generated tokens, sampling, trials, cold/warm | §9.10 is a 1.6× effect from protocol alone |

A real, machine-generated blob from a published community protocol looks like this
(✅ **VERIFIED** as a shipped submission, `notes/repos/john-rocky-models.md` §11.2):

```json
"environment": {
  "available_memory_mb": 6373,
  "battery_level": 0.9,
  "battery_state": "charging",
  "free_disk_gb": 64.9,
  "low_power_mode": false,
  "thermal_state_before": "nominal",
  "thermal_state_after": "nominal"
}
```

with the run itself recording device `iPhone18,1`, iOS 27.0 build `24A5355q`, 12.3 GB RAM,
`load_s: 3.4`, the bundle name, and the source HF revision. The project's own framing of why it is
machine-generated is the important part: *"The app measures and builds the result blob; **no number
in this table was typed by a human**."*

**If a human can type a number into your results table, a human will type the wrong number into
your results table.** Generate the blob.

### 9.2 Three questions, three rankings

The same device, the same day, the same model can produce three different rankings depending on
which question you asked. From the tables already given:

| Question | Metric | Winner in this corpus' iPhone data |
|---|---|---|
| "How fast does it feel on one tap?" | **Burst** tok/s, cold-ish | LiteRT-LM 56, MLX 48, ANE 33 (§7.3) |
| "What happens if it runs for ten minutes?" | **Sustained** tok/s at 600 s | LiteRT-LM 27, **ANE 22**, MLX 18 (§7.3) |
| "What does it cost the battery?" | **J/token** or tokens per 1% | ANE leads MLX by ~8.5%; the *other* GPU path is worst (§8.1) |

MLX is second on burst and **last** on sustained in that dataset. The ANE is last on burst and
second on sustained. Any single-number headline picks one of these and discards the others.

**Report all three, or say explicitly which one you measured.** "56 tok/s" with no qualifier is,
in this corpus, a claim that is 2× wrong for a plausible reading of the question.

### 9.3 State the build per row

The single most expensive omission found in this corpus was not a protocol error. It was not saying
*which file the runtime was handed*.

**Community-measured**, iPhone 17 Pro, Gemma 4 E2B, GSM8K n=100, `notes/web/community-blogs.md` §2.8:

| Runtime | Build | Decode tok/s | GSM8K |
|---|---|---:|---:|
| Cactus | CQ4 **uncalibrated** | 50.6 | **87.0%** |
| Cactus | **CQ4 as shipped** (`cactus run` default) | 50.2 | **3.0%** |

**Same engine. Same speed. Eighty-four points of accuracy.** The build the project *demoted* scores
87%; the build it *ships by default* scores 3%. The source's conclusion:

> "'Which file did the runtime hand you' is worth 84 points — the sharpest case yet for stating the
> build per row."

In the same table, Google's official QAT GGUF for the same model **does not load at all** —
*"llama.cpp aborts on a vocab defect ('empty token at index 237922')"*. As the source puts it:
**"Shipping an artifact ≠ shipping a usable artifact."**

A related framing from the same corpus, about the word "int4":

> "'int4' named **three different products** in this comparison. Google publishes **four** QAT
> checkpoints for Gemma-4 and they are not interchangeable."

| Variant | What it is | Who consumes it |
|---|---|---|
| Unquantized QAT (Q4_0) | half-precision weights from the QAT pipeline | Core AI, MLX builds |
| **Mobile-optimized (`wNa8o8`)** | *"targeted **2-bit decoding layers**, optimized **KV caches**, and **static activations**"* | LiteRT-LM `.litertlm` |
| GGUF (Q4_0) | ready to deploy | llama.cpp |
| Compressed Tensors (w4a16) | server | vLLM |

> "The mobile variant is a **co-designed weights+runtime package, not a bit-width**. It differs on
> three axes at once (2-bit layers → fewer bytes/token; optimized KV cache → less traffic *and*
> smaller footprint; int8 activations → a different arithmetic path). Comparing it to a generic
> Q4_0 build and calling the delta 'runtime speed' credits the engine with what is substantially
> the checkpoint's doing."

**"Bits are not a spec."** If you want to compare runtimes rather than checkpoints, the same source
gives the recipe: compile every arm from the *same* unquantized QAT checkpoint yourself, at the same
block size — e.g. `mlx_lm.convert --hf-path <qat-q4_0-unquantized> --mlx-path <out> -q --q-bits 4
--q-group-size 32` to match a Core AI int4-linear per-block-32 export. *"Then weights, recipe, and
block size are equal and the runtime is the only variable."*

### 9.4 Prefill and decode are different metrics

Reporting a single tok/s number conflates two phases with different bottlenecks, different hardware
sensitivities and different product consequences.

- **Prefill** (prompt processing) is compute-bound and batchable. It determines **time to first
  token**. It is the phase that responds to clock ramp (§7.1), to chunk thresholds (§9.6), and to
  matmul hardware.
- **Decode** (generation) is bandwidth-bound at small context. It determines **inter-token latency**.
  It is comparatively insensitive to clock (§7.1's canary) and sensitive to weight bytes read per
  token.

The two can move in opposite directions from the same change. In the corpus:
`COREAI_CHUNK_THRESHOLD` moved prefill from 766 to 1439 tok/s while *"decode is unaffected (~76–78
tok/s everywhere)"* (§9.6); a chunked-SSD prefill kernel gave **13.7×** on prefill and *"only 3–8%"*
on the decode kernel; and a fused wide prefill lane that helped on paper was killed at **−34% Mac /
−40% A19**.

**Why this matters more in 2026 than it did in 2024.** Apple's own framing, WWDC26 session 232:

> "**Agentic sessions usually comprise hundreds of thousands of tokens and most of those are not
> generated.**"

(Apple-published, WWDC26 session 232 at 78; `notes/transcripts/evals-mlx.md`.) The research note
draws the correct conclusion: agentic workloads are **prefill-dominated, not decode-dominated.**
If your product is a tool-calling agent, a document-grounded assistant, or anything that re-sends a
growing transcript, then decode tok/s is the number you will put on a slide and prefill tok/s is
the number your users will feel.

Which is also why prefix caching is the highest-leverage optimisation for multi-turn products:
community-measured turn-2 TTFT of **23.282 s → 0.230 s (101×)** at 4103 tokens, and 1.915 s →
0.126 s (15.2×) at 357 tokens, with byte-identical greedy output. See
[Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md) for the mechanism and its hard constraint (hybrid
and linear-attention architectures cannot do it at all).

Report the pair. A row that reads `prefill 70.4 / decode 68.7 tok/s` is informative; a row that
reads `69 tok/s` is not.

### 9.5 The artifact is not a function of the recipe

This is the finding that should change how you think about reproducibility on this stack.

**Community-measured**, iPhone 17 Pro (iOS 27 beta), same 512p/1024g/5-trial protocol,
`notes/repos/john-rocky-models.md` §7.2 (`apple-models-bench.md:46-54`):

| Variant | Prefill tok/s | Decode tok/s (run 1 / run 2) | Footprint |
|---|---:|---|---:|
| qwen3-0.6b GPU, **macOS-27β artifact** | 1,519 | 57.2 / 52.5 | 0.47 GB |
| qwen3-0.6b GPU, **macOS-26 artifact** | **5,807** | **115.1 / 90.4** | **0.22 GB** |

**Same recipe. Same code. Same wheels. Same command. Same device running them.** The only
difference is which macOS version ran the export. The result is roughly **2× decode, 3.8× prefill,
and half the memory**.

Restated by its author in that project's gotcha list:

> **"An `.aimodel` is a build artifact, not a pure function of the recipe"**: the same
> `coreai.llm.export qwen3-0.6b` produced a **2.2× faster artifact on macOS 26 than on the 27
> beta** (**native quantized-Linear lowering vs explicit dequant ops**; same code, same wheels). …
> **Version-stamp and keep your artifacts.**

Note that the mechanism is identified — the newer toolchain lost a native quantized-Linear lowering
and emitted explicit dequant ops instead — which is what elevates this from "betas are flaky" to a
concrete, actionable finding. It is a **regression in a beta toolchain**, community-measured, and
it will presumably be fixed. That does not make the lesson temporary:

> ⚠️ **SILENT FAILURE — your build machine is a benchmark variable, and nothing reports it.**
> No error, no warning, no diagnostic. The export succeeds. The artifact loads. It runs correctly
> and produces the right tokens. It is simply 2.2× slower and uses twice the memory, and the only
> way you find out is by measuring the artifact you actually shipped. **Benchmark the artifact you
> will ship, built on the machine you will ship from** — not a rebuild, not a "same recipe"
> reproduction, not a colleague's copy.

The same repository independently established that conversion is **not byte-deterministic**:

> Measured 2026-07-25: the same recipe run twice on the same machine, minutes apart, produces
> `.aimodel` bundles that differ from each other (**`main.mlirb` by 7 bytes, `main.hash`
> entirely**) — and the published bundle differs from both by **492 bytes out of 1.19 GB**.
> Conversion is not byte-deterministic, so "did this recipe reproduce the published bundle?" can
> only be answered **behaviourally**.

(Community-measured, `notes/repos/john-rocky-models.md` §3.4.) **Consequence: a stored hash is
worthless as a reproducibility criterion for these bundles.** Which in turn means: keep the
artifact, not the recipe. Version-stamp it. Record the producer — that project checks a
`producer: coreai-core 1.0.0b2` field on bundles — and treat a re-export as a **new artifact
requiring re-measurement**, not as a reproduction.

### 9.6 Read a "win" as a trade-off

The most instructive knob in the corpus is one that looks like a speed setting and is a memory
setting.

**`COREAI_CHUNK_THRESHOLD`** — an environment variable read by the Core AI engine, undocumented
beyond a hint in `llm-runner --help` that suggests *"use 128 for MoE"*. Community-measured on an
**M4 Max 128 GB**, gpt-oss-20b, 4096-token prefill, 3 trials
(`notes/repos/john-rocky-models.md` §7.2):

| Chunk threshold | Prefill tok/s | Peak dirty footprint |
|---|---:|---:|
| **128** (the "MoE hint") | 766 | **1.7 GB** |
| **1024** (default) | 1,237 | (not measured) |
| **8192** (no chunking) | **1,439** | **18.0 GB** |

> "Unchunked MoE prefill allocates **huge expert activations (~18 GB dirty for 4096 tokens** on top
> of the mmap'd weights). On a 16–32 GB Mac that would swap or jetsam — chunk 128 caps it at 1.7 GB
> for a **1.9× prefill cost**. On a big-RAM Mac, RAISE the threshold: **+16% prefill over the
> default for free**. **Decode is unaffected** (~76–78 tok/s everywhere)."

Read the two columns together. Going from 128 to 8192 buys **1.9× prefill** and costs
**10.6× peak footprint**. On a 128 GB workstation that is free money. On a 16 GB Mac it is a crash,
and on a phone it is not a conversation. The hint in the help text — "use 128 for MoE" — is
therefore **not a performance recommendation at all; it is a memory recommendation phrased as one.**

This generalises into a habit worth building:

> **When a knob changes throughput, measure memory in the same run. When a knob changes memory,
> measure throughput in the same run. A result with one column is not a result; it is half of a
> trade-off with the other half hidden.**

Two more instances of the same shape in this corpus:

- **`.fixedSize` KV** (§2.3): Apple's own comment says it costs memory **and** decode speed. A
  "safety" setting that is slow.
- **Debug builds.** Two independent findings. Apple's `coreai-models` package applies
  `.unsafeFlags(["-O"], .when(configuration: .debug))` with the comment: *"The per-token host loop
  dominates unoptimized: a **Debug engine measures ~3× slow** (zoo knowledge/pipelined-engine.md).
  Keep the engine optimized even in Debug app builds."* (✅ **VERIFIED**, as vendored,
  `notes/repos/noema-ios.md` §5.) And a benchmark project's fairness rule #7:
  *"**Build Release for real numbers** — a Debug build adds large per-token host overhead and
  understates decode."* — which the author notes **bit his own MLX row**. A cross-project
  contributing guide states the same bar flatly: *"Debug builds don't count — measure Release."*

### 9.7 Cold and warm are two numbers, not an average

The first-ever run of a model bundle includes on-device specialization — Core AI compiling the
portable graph for this specific GPU or ANE. It is not small.

**Community-measured** load times (`notes/repos/john-rocky-models.md` §7.5 table E):

| Event | Cold | Warm |
|---|---:|---:|
| gpt-oss-20b, M4 Max, incl. GPU specialization | **13.2 s** | 2.1 s |
| qwen3-0.6b ANE, iPhone 17 Pro | 2.85 s | **0.045 s** |
| qwen3-4b ANE `.aimodelc` (3 GB), iPhone 17 Pro | **194 s** | 0.46 s |
| Cold GPU specialization, 0.8B / 2.3 GB, iPhone | ≈ 4.8 s / ≈ 29 s | — |
| Nanbeige4.2-3B, iPhone 17 Pro, device gate | **31.7 s** | 10.8 s |
| `.aimodel` JIT → `.aimodelc` AOT, first cold load, int8 monolith, iPhone | 19.2 s → **4.9 s** (~4×) | 0.0 s both |

**194 seconds.** Three minutes and fourteen seconds, on a phone, on first launch, with no progress
API the user can see. The benching rule the source states:

> "The first-ever run of a bundle includes on-device GPU specialization (gpt-oss-20b: 13.2 s vs
> 2.1 s warm). **Don't average it into load-time numbers** — report both."

The product answer is AOT compilation: the last row shows a **~4× cold-load improvement**
(19.2 s → 4.9 s) from shipping a pre-compiled `.aimodelc` instead of a portable `.aimodel`, with the
OS cache serving both equally once warm. That is Part 10's and Part 7's territory; what belongs
here is the **measurement** rule and one caution — the same corpus records that six host-cache chunk
graphs **could not be AOT-compiled at all** because `coreai-build` itself SIGSEGV'd, described as a
*"beta compiler bug, size/shape-correlated."* So AOT is the answer where it works, and where it does
not, the cold number is the number your users get.

Also worth knowing for cache hygiene: each distinct `SpecializationOptions` configuration leaves
**its own multi-GB cache entry**, and a shipping app's recovery path is to clear them all:

```swift illustrative
if let cached = try? AIModelCache.default.model(for: url, options: options) { return cached }
do {
    return try await AIModel(contentsOf: url, options: options)
} catch {
    // Clear every cached variant of this model: each SpecializationOptions change
    // leaves its own multi-GB entry behind, and stale/evicted entries are the
    // documented way loads get wedged under storage pressure.
    try? AIModelCache.default.deleteEntries(for: url)
    …
}
```

✅ **VERIFIED** (community source, `notes/repos/noema-ios.md` §4.4;
`@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`). **Storage pressure and memory pressure are
connected here**: a wedged specialization cache presents as a load failure, not as a disk warning.

### 9.8 ⚠️ Foundation Models has no tokenizer, so every tok/s figure for it is an estimate

This one has to be said every single time such a number appears, including in this guide.

> ⚠️ **SILENT FAILURE — third-party tok/s figures for Apple's on-device model are estimates at
> roughly ±20%, and nothing marks them as such.**
>
> **`FoundationModels` does not expose a tokenizer.** A harness measuring `SystemLanguageModel`
> therefore cannot count tokens; it can only estimate them. The community benchmark that measured
> Apple's model states its method and its error bar explicitly:
>
> > "**Tokens are estimated** (`utf8.count / 4`) because **`FoundationModels` does not expose the
> > tokenizer**. Treat decode tok/s as **±20%**…"
>
> (Community-measured, `notes/web/community-blogs.md` §2.9.) The row that estimate produced —
> **apple-fm, 3 runs, TTFT 269 ms, decode 85.2 tok/s, 27 MB in-process peak** — is a perfectly good
> measurement of *something*, and every one of those three numbers needs a caveat: the tok/s is a
> ±20% estimate, the memory is harness overhead only (§1.4), and *"**Quant is Apple-internal**"* —
> community reverse-engineering puts it at ~2-bit base weights plus 4-bit task adapters, and
> **Apple has not published numbers.**
>
> **Consequence:** you cannot honestly put a Foundation Models tok/s number in the same column as
> an MLX or Core AI number where you counted real tokens. A ±20% error bar is larger than most of
> the runtime differences in §8's tables. **Report it as an estimate, in its own row, with the
> method (`utf8.count / 4`) named.**

Related, and confirmed independently: `contextSize` and `tokenCount(for:)` arrived in **iOS 26.4**
and are the supported way to reason about context occupancy — see
[Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md). They give you *token counts for inputs*; they do
not give you a tokenizer with which to count a stream of generated text, which is the thing a
throughput harness needs.

### 9.9 The harness that manufactured the result

The best methodology document in this corpus was written after a comparison **nearly published**
this:

> Scores about to be published: **Core AI 80% vs MLX ~20%. Both numbers were meaningless.**

**Community-measured**, Gemma-4-E2B GSM8K across Core AI / MLX / LiteRT-LM, written up 2026-07-17;
`notes/repos/john-rocky-models.md` §7.3. Four independent defects, each worth recognising:

1. **The arms ran the model in different modes.** *"Gemma-4 has a configurable thinking mode.
   **HF's `apply_chat_template` defaults to thinking ON. The same template rendered by
   swift-transformers … comes out thinking OFF**, and `llm-runner` exposes no flag to turn it on.
   One arm did chain-of-thought, the other answered directly — and the delta was about to be
   reported as runtime quality."*
   → **The renderer, not the model, decided the mode.** Two libraries, one template, opposite
   defaults.
2. **The token budget truncated the thinking arm.** Thinking-on needs ~250 tokens of reasoning
   before the answer; a GSM8K item needs 419–479 tokens; the budget was **512** — right at the
   cliff. *"Measured: same build, same weights → **~20% at 512, correct when given room**."*
   > **"A truncated reasoning arm is indistinguishable from a bad model. Nothing in the log says
   > 'truncated' — you get a confident wrong number."**
3. **The two defects hid each other.** *"The arm we had **handicapped** (Core AI, thinking off) was
   the one that **scored well**, because direct answers fit in 512. **The harness manufactured the
   result we would have liked.**"* This is the part to be frightened of. Two bugs whose product is
   a plausible, flattering, publishable number.
4. **Three of the four numbers had no stored report** and no recorded budget or mode. They were
   inherited from earlier sessions.

The same incident is referenced elsewhere in that repository as *"A 12-point 'quality gap' in this
repo's history turned out to be a 600-vs-2048 token cap difference."*

**The checklist that came out of it, reproduced as written:**

- **Same checkpoint.** *"Not 'both int4' — the same file."*
- **Same mode.** *"Thinking/reasoning defaults differ **per template renderer**, not just per model.
  Verify by grepping the raw generations for the thinking marker … **do not trust the template
  source**."*
- **Budget ≥ 2× the observed worst case.** *"Measure the worst case first … Never set the budget
  from the *typical* length."*
- **Check the truncation rate explicitly.** *"Count generations that hit `max_tokens` without
  emitting the answer marker. If it is not ~0, the score is a budget artifact."*
- **Probe-item parity before the full run.** One item through every arm; compare prompt token count,
  output token count, and answer. *"Ours: Core AI 76→195, MLX 75→197, both correct."*
- **Store a report per run** with `n`, `max_tokens`, mode, checkpoint, per-item predictions.

That is a *quality* checklist, and this is a performance guide — but items 2, 4 and 5 are latency
hazards too. A run that silently truncates is also a run whose tok/s denominator is wrong.

One more from the same file, because it is a beautiful technique: **use a hardware ceiling to
falsify your own assumption.**

> "Gemma-4 **gathers** its PLE, so model size ≠ bytes/token (**MLX at 181.9 tok/s × 3.3 GB =
> 600 GB/s would exceed the M4 Max's 546 GB/s peak** — proof that no arm reads its whole file per
> token)."

If your measured throughput implies a memory bandwidth above the machine's specification, your
model of what the runtime is doing is wrong. That check costs one multiplication and it catches a
whole class of misunderstanding.

### 9.10 Protocol swing, and interleaved A/B

**The same artifact measures 115 or 184 tok/s depending only on the protocol.**

Community-measured, macOS-26 GPU artifact of qwen3-0.6b on an iPhone 17 Pro, engine warm
(`notes/repos/john-rocky-models.md` §7.2):

| Protocol | Decode tok/s |
|---|---:|
| 512 prompt / 1024 generated | **115** |
| 128 prompt / 128 generated | **184–190** (median of 5 = 184; *"later trials drop to ~125 thermally"*) |

> "**Protocols matter**: the same artifact measures 115 (512p/1024g) and ~184 (128p/128g)."

A **1.6× swing from protocol alone** — because decode rate falls as the KV cache deepens. The same
project's benchmark file warns about this in its own table:
*"note this carries a much deeper KV than 'short-chat' benchmarks elsewhere; **numbers are NOT
comparable across protocols**."* Note the third column of that comparison too: the short protocol's
own trials *drop to ~125 thermally*, so the short-protocol number is also the least stable one.

Every macOS row in that project's Apple-artifact table carries a short-context figure in
parentheses for the same reason — qwen3-0.6b is **484 tok/s** at 512p/1024g and **558** short-ctx;
qwen3-8b is 94.1 and 102. **Decode is context-dependent, so a headline tok/s without a stated
protocol is meaningless.**

Two rules follow:

1. **Publish the protocol as part of the number**, not as a methods paragraph three sections away.
   `68.4 tok/s (pb-random-v1)` is a number. `68.4 tok/s` is a rumour.
2. **Compare arms in one interleaved session.** From the same corpus:
   *"pair both arms in one process, interleave ≥ 8 reps … **unpaired single-shot on a ±15%-drift
   machine will confirm anything.**"* And from the thermal-protocol note:
   *"cross-config claims need interleaved A/B, not different-day numbers."*

The magnitude of session drift is measurable, and one project measured its own:

> "a same-session LiteRT control re-ran at 60.9 decode… vs its published 52.7 — **this device runs
> ~16% faster today than in the 07-18 session**."

**16% between sessions on the same device with the same build.** Any cross-session comparison
smaller than that is noise. Run a control arm in every session; publish its drift.

### 9.11 A published protocol worth copying

`pb-random-v1`, from a community benchmark harness, is the most fully specified protocol in this
corpus and is a reasonable template (✅ **VERIFIED** as a published protocol,
`notes/repos/john-rocky-models.md` §3.3):

- Fixed **128-token random prompt (seed 0)** → **256 greedy decode tokens**.
- `S=1` prefill (`COREAI_CHUNK_THRESHOLD=1`) — i.e. the knob is *pinned*, not left at whatever the
  environment had.
- **1 cold + 3 warm runs on a freshly created engine.**
- Cell value = median across submissions of **each submission's median warm decode tok/s**.
- `n` = accepted submissions; **`n < 3` is marked provisional.**
- **Environment filter**: Low Power Mode on, or serious/critical thermal state before the run →
  excluded, **and the exclusion count is published.**
- Aggregated by script; the file header says *"do not edit by hand."*
- Labelled honestly: *"**NOT** a controlled-environment benchmark — background load and heat show
  up here as real-world variance."*

Design notes worth stealing: a **random seeded prompt** (no cache-friendly repetition, reproducible
across submitters), **greedy decode** (removes sampling variance), **median-of-medians** (robust to
one bad submitter), and an explicit **provisional** marker below n=3.

Its own cross-check is instructive about how much residual variance survives all that: the protocol
reports qwen3.5-0.8b at **68.4 tok/s** on iPhone 17 Pro while the same project's README headline
gives **71.9** — *"~5% apart, consistent with different prompts/thermal state."* **Five percent is
the floor of what a well-specified protocol achieves on a phone.** Do not report differences
smaller than that as differences.

The same project's contribution bar is a good summary of the whole section
(`CONTRIBUTING.md`, community source):

- **License** — must permit redistributing converted weights.
- **Parity** — teacher-forced / oracle top-1 parity vs the fp32 reference, plus a greedy rollout
  sanity check.
- **Real hardware** — Apple silicon Mac minimum; *"Debug builds don't count — measure Release."*
- And the device gate: *"Do not report iPhone numbers you did not measure, and do not let an
  unmeasured device claim reach a card."* — with the explicit note that *"a gate can also come back
  **no-go**, which is still a result worth publishing."*

That last clause is the one most teams skip. **Publish the failures.** The §3 failures in this
guide are the most useful content in it, and they exist only because someone wrote down a run that
died.

---

## 10. The measurement checklist

Two artefacts to paste into a harness: an environment capture, and a checklist.

### 10.1 Environment capture

This struct records everything §9.1 asks for, plus the memory signals from §1.3, and emits a blob
no human typed. Adapt the field names to your schema; do not drop fields.

```swift illustrative
//  BenchmarkEnvironment.swift
//
//  Records the environment a measurement was taken in. Every field here exists
//  because a number in this corpus was wrong without it.
//
//  Version floor: iOS 18 / macOS 26 for everything in this file. The Core AI and
//  MLX fields you add alongside it have their own floors (iOS 27 / macOS 27 for
//  Core AI; the MLX package's own version axis for MLX).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@_silgen_name("app_available_memory") fileprivate func c_app_available_memory() -> UInt
@_silgen_name("app_memory_footprint") fileprivate func c_app_memory_footprint() -> UInt

struct BenchmarkEnvironment: Codable, Sendable {

    // ---- Identity -----------------------------------------------------------
    /// The hardware identifier, e.g. "iPhone18,1". NOT the marketing name:
    /// marketing names collide across RAM/storage configurations (§1.4).
    let deviceIdentifier: String
    /// e.g. "iOS 27.0 (24A5355q)". The BUILD, not just the version (§9.5).
    let osVersion: String
    /// Xcode / SDK that produced the binary, and the machine that produced the
    /// model artifact if different (§9.5 — a 2.2x effect).
    let toolchain: String
    let buildConfiguration: String        // "release" or "debug" — a 3x effect (§9.6)
    let capturedAt: Date

    // ---- Environment --------------------------------------------------------
    let thermalStateBefore: String        // .nominal / .serious / .critical
    var thermalStateAfter: String?        // filled in after the run
    let lowPowerMode: Bool
    let batteryLevel: Float?              // -1 where unavailable
    let batteryState: String?             // "charging" changes clock policy
    let freeDiskBytes: Int64?
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64

    // ---- Memory signals (§1.3) ---------------------------------------------
    let availableMemoryBytesBefore: Int64
    let footprintBytesBefore: Int64
    var availableMemoryBytesAfterLoad: Int64?
    var footprintBytesAfterLoad: Int64?
    /// The step everyone skips (§3.2). Load success is not a fit test.
    var availableMemoryBytesAfterFirstToken: Int64?
    var footprintBytesAfterFirstToken: Int64?
    var peakFootprintBytes: Int64?
    /// Report BOTH: footprint = "what inference allocates";
    /// RSS = "how much RAM do I need" and includes clean mmap'd weights (§2.2).
    var peakResidentSetBytes: Int64?

    // ---- Artifact (§9.3 — worth 84 points) ---------------------------------
    let artifactIdentifier: String        // repo / path / bundle name
    let artifactRevision: String?         // immutable revision, not "main"
    let artifactBytes: Int64?
    let quantizationDescription: String   // "int4 linear, per-block-32" — not "4-bit"
    let producer: String?                 // e.g. exporter version stamp

    // ---- Protocol (§9.10) ---------------------------------------------------
    let protocolName: String              // e.g. "pb-random-v1"
    let promptTokens: Int
    let generateTokens: Int
    let sampling: String                  // "greedy" removes a variance source
    let trials: Int
    let isCold: Bool                      // NEVER average cold into warm (§9.7)
    /// Environment variables that change memory or speed. Pin them; record them.
    let pinnedEnvironment: [String: String]   // e.g. ["COREAI_CHUNK_THRESHOLD": "1"]

    // ---- Estimation caveats (§9.8) -----------------------------------------
    /// True when tok/s was derived without a real tokenizer. FoundationModels
    /// exposes none, so utf8.count/4 estimates carry roughly +/-20%.
    let tokenCountIsEstimated: Bool
    let tokenEstimationMethod: String?    // "utf8.count / 4"

    static func capture(artifact: String,
                        artifactRevision: String? = nil,
                        quantization: String,
                        protocolName: String,
                        promptTokens: Int,
                        generateTokens: Int,
                        sampling: String = "greedy",
                        trials: Int,
                        isCold: Bool,
                        pinnedEnvironment: [String: String] = [:],
                        tokenCountIsEstimated: Bool = false,
                        tokenEstimationMethod: String? = nil) -> BenchmarkEnvironment {

        let info = ProcessInfo.processInfo
        let disk = try? FileManager.default
            .attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64

        return BenchmarkEnvironment(
            deviceIdentifier: Self.hardwareIdentifier(),
            osVersion: "\(info.operatingSystemVersionString)",
            toolchain: Self.toolchainStamp(),
            buildConfiguration: Self.buildConfiguration(),
            capturedAt: Date(),
            thermalStateBefore: Self.describe(info.thermalState),
            thermalStateAfter: nil,
            lowPowerMode: info.isLowPowerModeEnabled,
            batteryLevel: Self.batteryLevel(),
            batteryState: Self.batteryState(),
            freeDiskBytes: disk ?? nil,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            availableMemoryBytesBefore: Int64(c_app_available_memory()),
            footprintBytesBefore: Int64(c_app_memory_footprint()),
            availableMemoryBytesAfterLoad: nil,
            footprintBytesAfterLoad: nil,
            availableMemoryBytesAfterFirstToken: nil,
            footprintBytesAfterFirstToken: nil,
            peakFootprintBytes: nil,
            peakResidentSetBytes: nil,
            artifactIdentifier: artifact,
            artifactRevision: artifactRevision,
            artifactBytes: nil,
            quantizationDescription: quantization,
            producer: nil,
            protocolName: protocolName,
            promptTokens: promptTokens,
            generateTokens: generateTokens,
            sampling: sampling,
            trials: trials,
            isCold: isCold,
            pinnedEnvironment: pinnedEnvironment,
            tokenCountIsEstimated: tokenCountIsEstimated,
            tokenEstimationMethod: tokenEstimationMethod)
    }

    /// Refuse to measure a device that is already compromised (§7.2).
    /// Publish the exclusion count; do not silently drop runs.
    func passesEnvironmentFilter() -> Bool {
        thermalStateBefore == "nominal" && lowPowerMode == false
    }

    static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: MemoryLayout.size(ofValue: systemInfo.machine)) {
                String(cString: $0)
            }
        }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"   // do not assert cases you have not seen
        }
    }

    static func buildConfiguration() -> String {
        #if DEBUG
        return "debug"   // -> your numbers are not quotable (§9.6)
        #else
        return "release"
        #endif
    }

    static func toolchainStamp() -> String {
        // Inject at build time (e.g. an Info.plist key set from a build phase);
        // there is no runtime API that reports which Xcode built you.
        (Bundle.main.infoDictionary?["ToolchainStamp"] as? String) ?? "unstamped"
    }

    #if canImport(UIKit) && !os(watchOS)
    static func batteryLevel() -> Float? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : level
    }
    static func batteryState() -> String? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging: return "charging"
        case .full:     return "full"
        case .unplugged: return "unplugged"
        default:        return nil
        }
    }
    #else
    static func batteryLevel() -> Float? { nil }
    static func batteryState() -> String? { nil }
    #endif
}
```

**Evidence markers for that file.** ✅ **VERIFIED**: the two `@_silgen_name` bridges and the C
functions behind them (§1.3); `ProcessInfo.processInfo.thermalState` with `.nominal` / `.serious` /
`.critical`; `ProcessInfo.processInfo.activeProcessorCount`; `ProcessInfo.processInfo.physicalMemory`;
`utsname().machine` as the device-identifier source; the JSON field set, which mirrors a real
submitted blob (§9.1). 🟡 **RECONSTRUCTED**: `info.isLowPowerModeEnabled` (the concept and a
shipping app's `lowPowerMode: Bool` field are attested; this exact `ProcessInfo` spelling is
inferred), and the `UIDevice` battery calls (standard UIKit, not attested in this corpus — verify
before shipping). 🔴 **GAP**: there is **no runtime API in this corpus that reports which Xcode
built the binary**; `toolchainStamp()` reads a build-phase-injected key, which is the safe default.

### 10.2 The checklist

Print this. Work down it before you quote a number to anyone.

**Before the run**

- [ ] Physical device, not Simulator.
- [ ] **Release** build. (Debug: ~3× slow on the Core AI host loop; understates MLX decode. §9.6)
- [ ] `thermalState == .nominal` and Low Power Mode **off** — or the run is excluded, and the
      **exclusion count is published**. (§7.2, §9.11)
- [ ] Device identifier (`iPhone18,1`), **OS build** (`24A5355q`), Xcode/SDK, and the machine that
      produced the model artifact, all recorded. (§9.1, §9.5)
- [ ] The **exact artifact**: repo, immutable revision, file, size, quantization scheme *and block
      size* — "int4 linear per-block-32", not "4-bit". (§9.3)
- [ ] Every environment variable that moves memory or speed is **pinned and recorded**
      (`COREAI_CHUNK_THRESHOLD`, cache/memory limits, thread counts). (§9.6, §9.11)
- [ ] Protocol declared: prompt tokens, generated tokens, sampling, trials, cold/warm. (§9.10)
- [ ] Token budget ≥ **2× the observed worst case**, and you measured the worst case first. (§9.9)

**During the run**

- [ ] Warm-up: discard at least one full-shape run to let the GPU clock ramp. **Never quote a
      cold-start burst number alone.** (§7.1)
- [ ] Sample `os_proc_available_memory()` and `phys_footprint` **before load, after load, after the
      first generated token**, and at 1 Hz throughout. (§1.3, §3.2)
- [ ] Record **peak footprint AND peak RSS**, labelled. They differ by the mmap'd weight file. (§2.2)
- [ ] Comparing two configurations? **Interleave them in one session**, ≥ 8 reps. Different-day
      numbers do not compare. (§7.2, §9.10)
- [ ] Run a **control arm** every session and record its drift against the last session.
      (16% observed. §9.10)
- [ ] Watch the **decode canary**: a decode rate sliding below its steady-state floor means the
      device is genuinely warm, even while thermal state still reads `nominal`. (§7.1, §7.4)

**Reporting**

- [ ] **Prefill and decode reported separately.** Agentic workloads are prefill-dominated. (§9.4)
- [ ] **Cold and warm load times reported separately**, never averaged. (§9.7)
- [ ] **Burst, sustained and energy** are three different questions. Say which one this is; ideally
      give all three. (§9.2, §7.3, §8)
- [ ] Thermal state **before and after**, plus battery level and charging state. (§9.1)
- [ ] Any Foundation Models tok/s figure marked as an **estimate, ±20%, method named** — because
      `FoundationModels` exposes no tokenizer. (§9.8)
- [ ] Any out-of-process model's memory marked as **harness overhead**, not model footprint. (§1.4)
- [ ] Every knob change reported as a **trade-off**: throughput *and* memory, in the same run. (§9.6)
- [ ] **Failed runs published**, including jetsams. A no-go is a result. (§9.11)
- [ ] Nothing inherited. If you cannot re-run it, do not cite it. (§9)
- [ ] Attribution on every number: Apple-published / community-measured / measured by you — with
      hardware, OS build, and date.

**Shipping (not benchmarking, but the same evening's work)**

- [ ] `com.apple.developer.kernel.increased-memory-limit` on the target. (§1.4)
- [ ] A two-gate fit check before load: incremental allocation **and** total logical working set.
      (§2.6)
- [ ] An unload path, a background unload policy, and **verification that the unload freed memory**.
      (§4.3, §4.4)
- [ ] A generation-length cap on iOS rather than running to EOS. (§3.3)
- [ ] Thermal state as an input to thread count, warmup and paged launches. (§7.5)
- [ ] Every embedded runtime's default cache ceilings audited for numbers chosen on a Mac. (§6.2)

---

## 11. Declared gaps

Stated plainly, with what would resolve each and what to do meanwhile.

### G1 — The MLX Swift memory-dial spelling

🔴 **GAP.** Two spellings are attested in 2026 code: `MLX.GPU.set(cacheLimit:)` in a shipping App
Store app against `mlx-swift` branch `main`, and `Memory.cacheLimit` / `Memory.memoryLimit` /
`Memory.snapshot()` throughout `mlx-swift-examples`, whose research note says the old idiom *"does
not appear anywhere in this repo."* Unknown: whether the old spelling survives as a deprecated
alias, which mlx-swift version introduced `Memory`, and whether `Memory` is an `enum`, `struct` or
`actor`. **Resolution:** `grep -rn 'cacheLimit' Sources/MLX/` in your resolved revision.
**Safe default:** the one-function shim in §5.1. Full detail there.

### G2 — Where the Core AI depth jetsam wall is

🔴 **GAP.** A community benchmark had to shorten its protocol to 192 tokens per repetition *"to stay
under its depth jetsam wall"* on iPhone, and its own summary says the wall is *"real, measured, but
no one has characterized where it is or whether an API controls it."* **Resolution:** a depth sweep
at fixed device/bundle recording footprint and available memory per step until the kill, repeated
across `KVCacheStrategy` values and `COREAI_CHUNK_THRESHOLD` settings. **Safe default:** cap
generation length explicitly, treat `.fixedSize` KV as a deliberate ceiling, instrument every
generation. Full detail in §3.3.

### G3 — The forum MPS "other allocations" report

🔴 **GAP.** Developer Forums thread 824753 reports the MPS backend seeing ~40 GiB of "other
allocations" on a 48 GB M5 Pro under macOS 26.4.1, blocking large PyTorch tensor operations. **No
Apple-staff reply is recorded in this corpus and the resolution status is unknown as of 2026-07-27.**
**Resolution:** the thread itself, or a reproduction with `vm_stat` / Instruments' allocations
against a controlled workload. **Safe default:** §6.2 — never size "as big as fits", re-read your
budget rather than caching it, and leave the OS the headroom Apple's own macOS guidance asks for.

### G4 — The energy table's provenance

🔴 **GAP.** The iPhone tokens-per-1%-battery table in §8.1 (ANE 6,144 / MLX 5,662 / Core AI GPU
4,506) is cited by its repository to
`litertlm-convert/reports/coreai-ane-gpu-parity-addendum.md`, a file **not present in that
repository**. It is flagged UNVERIFIED at source in our research notes. **Resolution:** the report
file, or an independent re-measurement with the matched 4-bit bundles named in that row.
**Safe default:** treat the table as directional. The *durable* claims it supports — throughput
parity rather than an ANE speed win, and GPU exclusivity as the real ANE advantage — are the
author's own conclusions and are stated more conservatively than the numbers.

### G5 — `ProcessInfo` spellings this corpus does not literally attest

🟡 **RECONSTRUCTED.** `ProcessInfo.processInfo.isLowPowerModeEnabled` is inferred from a shipping
app's `Environment { thermalState: ProcessInfo.ThermalState; lowPowerMode: Bool; … }`. The
`ProcessInfo.ThermalState` cases exercised anywhere in this corpus are **`.nominal`**, **`.serious`**
and **`.critical`**; §10.1's `switch` therefore carries an `@unknown default`. The `UIDevice`
battery calls in §10.1 are standard UIKit but are **not attested in this corpus** — verify them
against the SDK before shipping. **Resolution:** the `Foundation` and `UIKit` interfaces in your SDK.

### G6 — No runtime API reports the building toolchain

🔴 **GAP.** §9.5 establishes that the build machine's OS version is a first-order benchmark
variable (2.2× throughput, 2× memory, same recipe). There is **no runtime API in this corpus that
tells a running binary which Xcode or which macOS produced it or its model artifacts.** **Safe
default:** inject a toolchain stamp at build time into `Info.plist` and read it from
`BenchmarkEnvironment.toolchainStamp()`, and version-stamp model artifacts separately — a stored
hash will not help you, because conversion is not byte-deterministic (§9.5).

### G7 — Quantitative memory model for Core AI and ANE loads

🔴 **GAP.** §3.2 records that the same 1.8 GB core left ~2.8 GB of headroom on the ANE path and
~6.0 GB on the GPU path, and no source in this corpus explains or predicts that 3.2 GB difference.
Nothing in `SpecializationOptions`, `InferenceFunctionDescriptor` or the bundle metadata is
documented to report a projected load or first-step working set. **Resolution:** an instrumented
sweep across compute units and model sizes with footprint sampled around load and first token — the
exact protocol in §3.2's code block. **Safe default:** measure it per bundle per compute unit on a
real device, treat load success as meaningless without a first-token test, and keep the measured
delta in your artifact metadata so your fit gate can use it.

---

## Where to go next

- **The other half of shipping**: distribution, Background Assets, asset packs, updates and storage
  reclamation — [Part 15 guide 1](../README.md).
- **MLX in a Swift app** end to end, including the package layout and the concurrency model that
  §5's APIs live inside — [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md).
- **KV caches, prefix reuse, and the 101× multi-turn TTFT result** that §9.4 points at —
  [Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).
- **Core AI states, engines and specialization**, including AOT compilation as the answer to §9.7's
  194-second cold load — [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md) and
  [Part 10](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/README.md).
- **Quantization**, the single largest lever on every number in this guide —
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Evaluations**, because §9.9's harness failure was a quality-measurement failure and the same
  discipline applies — [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md).

---

## Sources

Every claim in this guide traces to one of the following research notes, read this session. Where a
note attributes a number to a file inside a repository, that inner citation is given at the claim.

| Note | What it supplied |
|---|---|
| `notes/repos/noema-ios.md` | The shipping-app memory stack: the C bridges for `os_proc_available_memory()` / `phys_footprint`, `DeviceRAMInfo`, `ModelRAMAdvisor`'s estimate breakdown and two-gate launch check, `LiveMemoryPressureSnapshot`, `OverfitMemoryGovernor`, `BackgroundModelUnloadPolicy`, `ModelUnloadVerifier`, `GenerationPowerPolicy`, the MLX GPU-cache refcount, entitlements, and the vendored `coreai-models` `EngineOptions` / `KVCacheStrategy` documentation. Community source throughout. |
| `notes/repos/john-rocky-models.md` | The DVFS-ramp measurement, the 18 GB `signal 9` and load-OK/run-dead failures, the macOS-26-vs-27β artifact A/B, `COREAI_CHUNK_THRESHOLD`, the cold/warm load table, the protocol-swing measurement, `pb-random-v1`, the cross-runtime quality-harness post-mortem, and the iPhone energy table (whose own source file is missing — G4). Community source throughout. |
| `notes/web/community-blogs.md` | Sustained-throughput retention (600 s), the M4 Max J/token table, the seven-runtime iPhone table with the 84-point build finding, the Core AI depth-wall observation, and the Foundation Models ±20% tokenizer caveat. Community-measured. |
| `notes/forums/forum-pain-points.md` | Apple-staff answers: no NPU priority entitlement (833666), `SystemLanguageModel` out-of-process and XPC-restricted extensions (833575); and the MPS "other allocations" thread title (824753). |
| `notes/repos/mlx-swift-lm.md` | Wired-memory policies, `WiredMemoryUtils`, `WiredMemoryMeasurement`, the KV sizing formula, `GPU.maxRecommendedWorkingSetBytes()`, and the weight-bytes measurement. |
| `notes/repos/mlx-swift-examples.md` | The `Memory` namespace surface with call sites, per-app cache/memory limits, the low-memory detection pattern, and the increased-memory-limit entitlement across every sample. |
| `notes/repos/issues-mlx-stack.md` | Expert-offload sizing (the "peak, not a monotone" curve), the lazy-load 18.2 GB spike, the array-view pinning finding, the unbounded prompt cache, the 33.9 GB VLM buffer, and the pressure-triggered use-after-free. |
| `notes/repos/issues-coreai-stack.md` | `std::bad_alloc` as a jetsam signature and the entitlement fix (#112); the iPad Flux2 wedge, the 3.85 GB heap request, and the per-call `InferenceFunction` leak (#77, #110). |
| `notes/repos/apple-coreai-models.md` | Apple-published platform guidance: iOS "keep models under 2 GB", macOS "leave at least 6 GB of RAM headroom", use `os_proc_available_memory()`, prefer `.default` specialization options. |
| `notes/transcripts/evals-mlx.md` | WWDC26 session 232: *"Agentic sessions usually comprise hundreds of thousands of tokens and most of those are not generated."* |
| `notes/CORRECTIONS-PENDING.md` | Checked for items naming Part 15. None apply directly; C5's prefix-cache/hybrid constraint and C4's `@Generable`-needs-logits constraint are cross-referenced where they bear on measurement (§9.4) and backend choice (§8.1). |

[^background-inference-entitlement]: Apple’s entitlement reference specifies the background Neural
    Engine requirement for Core AI, Core ML, and MPS Graph:
    [Background Inference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference).
    Compute-unit preference remains a separate Core AI concern documented in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
