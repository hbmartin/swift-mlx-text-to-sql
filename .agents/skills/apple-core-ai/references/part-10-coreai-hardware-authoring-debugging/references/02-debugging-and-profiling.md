# The debug gauge, the Core AI Instrument, and the Core AI Debugger

**Part 10 · Core AI: hardware authoring, debugging, LLM deployment · Reference 02**

**Version floor.** Everything in this guide is **27.0 and only 27.0**: Core AI ships as
`iOS 27.0+ · iPadOS 27.0+ · Mac Catalyst 27.0+ · macOS 27.0+ · tvOS 27.0+ · visionOS 27.0+ ·
watchOS 27.0+`, every symbol carrying a **Beta** flag. You need **Xcode 27** for the debug gauge
and the Instruments template. **Core AI Debugger is a separate download** with its own floor: host
**macOS 27 or later**, paired devices **iOS 27+, iPadOS 27+, or macOS 27+** (no visionOS, tvOS or
watchOS in the paired-device list). On the Python side the debugging APIs described here need
**`coreai-torch` 0.4.1 or later** — 0.4.0 produces assets the beta-2 compiler refuses to load, which
is the closing story of this guide — alongside `coreai-core 1.0.0b2`, `coreai-opt 0.2.1`, and a
pinned `torch==2.9.0`. Nothing here back-deploys to 26.x, because Core AI did not exist in 26.x.

> ⚠️ **Read this before you trust any signature below.** Core AI has **zero Apple sample-code
> projects** — verified: 0 `sampleCode` entries across all 312 indexed Core AI symbols, and
> `/documentation/updates/coreai` returns 404. Unlike Parts 1–6 there is no compiling first-party
> reference to check against. The strongest evidence for this guide is, in order: the shipped
> repositories (`apple/coreai-torch`, `apple/coreai-optimization`, `apple/coreai-models`), Apple's
> own agent skills inside those repos, Apple's documentation articles, and the WWDC26 transcripts.
> Every claim below is marked ✅ VERIFIED / 🟡 RECONSTRUCTED / 🔴 GAP accordingly, and the GAPs are
> real — **nobody in this corpus has run Xcode 27's Instruments or the Core AI Debugger by hand.**

---

## What this covers

Three tools, at three levels, answering three different questions about a model that is already
converted:

| | Question it answers | Where it lives | Cost to reach for |
|---|---|---|---|
| **Core AI debug gauge** | *Is anything happening, and is it happening when I expect?* | Xcode Debug navigator | free — it is already running |
| **Core AI instrument** | *Where is the time going, on which compute unit, and how often?* | Instruments template | a profiling run |
| **Core AI Debugger** | *Which operation is producing the wrong numbers, and which Python line wrote it?* | standalone macOS app | a download and a specialization |

The spine of the guide is the two worked diagnoses Apple actually demonstrated on stage:

- **A latency curve that grows** (WWDC26 session 324). Inference intervals visibly widening across a
  trace exposed a transformer with no KV cache; after adding Core AI **states**, the same trace
  showed latency growing far more slowly. This is the canonical "what a bad shape looks like in the
  Instruments timeline" example, and it is one of the very few places where Apple showed a
  *before and after* trace for the same app.
- **A model load with a large specialization sub-event sitting in the middle of a user-interactive
  flow** (WWDC26 session 326). One glance at the trace turned a mysterious spinner into a
  deployment-architecture decision: first-run experience, Background Assets, ahead-of-time
  compilation.

and the one Apple demonstrated for numerics (session 325): a 4-bit quantization of SAM3 that
silently stopped detecting an occluded flower, diagnosed in the Core AI Debugger by sorting sync
points by similarity, noticing that the low-PSNR pairs clustered in the **detector decoder**,
realising the detector is only **4% of the model's parameters**, and excluding it from the
quantization scheme — baseline quality back, at a fraction of the size.

Also covered: `coreai-opt`'s own inspection surface (`ModelInspector`, the activation-comparison
SNR table, graph-mode troubleshooting), the programmatic layer in `coreai_torch.debugging` that
does in Python what the Debugger does in a window, and — at the end — the incident that explains
why **asset provenance** is a debugging concern and not a bookkeeping one.

## What this does *not* cover

- **Making the model faster once you know where the time goes.** Compute-unit selection, chunking,
  BC1S re-authoring and the three-function split are Part 10 reference 01 and Part 8.
- **Choosing a compression scheme.** Part 9. This guide covers how to *find out* that your scheme
  broke something; Part 9 covers what to do about it.
- **`AIModelCache`, `coreai-build`, and the specialization lifecycle.** Part 7 reference 02. This
  guide only shows you what specialization *looks like* in a trace.
- **Foundation Models' Instruments template.** Different template, different lanes, Part 5.

## What you need

- **Xcode 27**, with the **Metal Toolchain** installed (Xcode ▸ Settings ▸ Components ▸ Other
  Components ▸ Metal Toolchain, or `xcodebuild -downloadComponent MetalToolchain`). Without it,
  any target containing an `.aimodel` fails to build with a missing-Metal-compiler error, and
  `coreai-build` does not run. This is the single most common first-build failure in the stack.
- **A real device.** Apple says it twice in one article: profile on real hardware, and run your app
  on its own, because other apps competing for CPU, GPU or Neural Engine distort the trace.
- **Core AI Debugger**, from `https://developer.apple.com/core-ai-debugger/` (Apple Account sign-in,
  free registration, developer agreement). It is not bundled with Xcode.
- A Python environment with `coreai-torch` ≥ 0.4.1 if you intend to produce reference data.

---

## Contents

1. [Three tools, one topology](#1-three-tools-one-topology)
2. [The debug gauge](#2-the-debug-gauge)
3. [The Core AI instrument](#3-the-core-ai-instrument)
4. [Worked trace 1 — inference intervals that grow](#4-worked-trace-1--inference-intervals-that-grow)
5. [Worked trace 2 — a specialization sub-event in an interactive flow](#5-worked-trace-2--a-specialization-sub-event-in-an-interactive-flow)
6. [Core AI Debugger — the workspace](#6-core-ai-debugger--the-workspace)
7. [Why the Navigator can group by PyTorch module](#7-why-the-navigator-can-group-by-pytorch-module)
8. [Running the model on a device from the Debugger](#8-running-the-model-on-a-device-from-the-debugger)
9. [`save_intermediates` and the reference run](#9-save_intermediates-and-the-reference-run)
10. [Sync points and the five similarity metrics](#10-sync-points-and-the-five-similarity-metrics)
11. [The worked diagnosis — SAM3's missing flower](#11-the-worked-diagnosis--sam3s-missing-flower)
12. [`coreai-opt`'s own debugging surface](#12-coreai-opts-own-debugging-surface)
13. [`coreai_torch.debugging` — the same jobs, in Python](#13-coreai_torchdebugging--the-same-jobs-in-python)
14. [A playbook: which tool, in which order](#14-a-playbook-which-tool-in-which-order)
15. [⚠️ Provenance: the coreai-torch 0.4.0 IR-location incident](#15-️-provenance-the-coreai-torch-040-ir-location-incident)
16. [Quick reference](#16-quick-reference)
17. [Sources and evidence ledger](#17-sources-and-evidence-ledger)

---

## 1. Three tools, one topology

Apple describes the split in one paragraph, and it is worth reading closely because it tells you
which tool owns which artifact:

> ✅ **VERIFIED** — Apple documentation, *Inspecting, debugging, and profiling Core AI models*
> (`/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models`):
> *"Core AI provides **three tools** to help you investigate model behavior, monitor activity, and
> profile performance. Use them as needed while authoring a model, after integrating it, or when
> your app is running.*
> - ***Core AI Debugger**: A standalone macOS app for inspecting model structure, running models,
>   and validating inference against reference data.*
> - ***Core AI debug gauge**: An Xcode feature that monitors model load, specialization, and
>   inference activity in real time during a debug session.*
> - ***Core AI instrument**: An Instruments template that profiles execution timing across the CPU,
>   GPU, and Neural Engine."*

and then the sentence that actually defines the architecture:

> ✅ **VERIFIED** — same page:
> *"The Core AI debug gauge and Core AI instrument focus on a model that's **already running inside
> your app**. Core AI Debugger works **directly with the `.aimodel` file** and gives you a closer
> look when something the gauge or instrument flags needs deeper inspection. **The tools share data,
> so a finding in one often leads to a closer look in another.**"*

So: two of the three tools observe your *app*; one observes your *asset*. The gauge and the
instrument can tell you that inference took 84 ms and ran on the GPU. Neither can tell you that
`layer_23.self_attn.o_proj` is producing garbage. The Debugger can do the second and knows nothing
about your app.

### 1.1 The data-flow diagram, in words

Apple's own workflow figure has unusually informative alt-text, and it is the only description of
the *whole* topology anywhere in the corpus:

> ✅ **VERIFIED** — figure alt-text on the same page:
> *"A two-phase workflow diagram. In the **Development** phase, authoring and optimization sends
> reference data to Core AI Debugger and saves an .aimodel file. The .aimodel file provides numeric
> debug data to Core AI Debugger and integrates into an app in the **Runtime** phase. The app runs
> into the Core AI debug gauge, which captures data back to Core AI Debugger and captures a trace
> into the Core AI instrument. The app also profiles directly into the Core AI instrument."*

Redrawn as a graph:

```
  ── DEVELOPMENT ────────────────────────────────────────────────────────────
   PyTorch authoring + coreai-opt
        │                                   │
        │ save_intermediates(...)           │ TorchConverter → .aimodel
        │  → *.aimodelintermediates         │  (carries numeric debug data)
        ▼                                   ▼
   ┌──────────────────────────────────────────────────┐
   │              Core AI Debugger (macOS 27+)        │
   └──────────────────────────────────────────────────┘
        ▲                    ▲
        │ "Open in Core AI   │
        │  Debugger"         │
  ── RUNTIME ────────────────┼───────────────────────────────────────────────
                             │
      your app ──────► Core AI debug gauge ──"Profile in Instruments"──┐
          │                (Xcode Debug navigator)                     │
          └───────────────── Product ▸ Profile ─────────────────► Core AI instrument
```

Two edges in that diagram are the ones people miss:

1. **The gauge can hand an event to the Debugger.** Not the app, not the trace — a *specific
   inference event*, with its input tensors.
2. **The `.aimodel` itself carries numeric debug data.** The Debugger's source mapping is not
   reconstructed by the app or by Xcode; it was baked in at conversion time. §7 and §15 are both
   consequences of that single fact.

### 1.2 The decision table

| Symptom | Reach for | Why |
|---|---|---|
| "Is the model even loading?" | gauge | It shows Load events live, with zero setup beyond linking. |
| "The app stalls once, at a specific moment" | instrument | Specialization sub-events are only visible here (§5). |
| "Second inference is slower than the first, and the third slower still" | instrument | You need the interval shape over time (§4). |
| "It runs, but the answer is wrong" | Debugger | The other two tools have no concept of a tensor value. |
| "It got worse after I compressed it" | Debugger + `save_intermediates` | This is exactly what sync points exist for (§10, §11). |
| "It ran on the CPU and I wanted the ANE" | instrument | The template ships a Neural Engine instrument alongside the Core AI one (§3.2). |
| "It won't load at all, with an MLIR error" | neither — see §15 | This is a provenance problem, not a numerics or timing one. |
| "I want the input tensors that produced *that* bad output" | gauge → Export to file | The gauge is the **only** way to capture them (§2.5). |

### 1.3 What "three levels" means in practice

Apple's stated ordering, from the framework introduction:

> ✅ **VERIFIED** — WWDC26 session 324, *Meet Core AI* (Ben), lines 137–140:
> *"In addition to debugging performance, it's also crucial to be able to **debug the numerics** of
> your converted model. For this you can use the **Core AI Debugger** which allows you to
> **visualize your converted model**, **easily inspect intermediate tensor values**, and **trace
> back operations in the converted model to the Python source code which introduced them**. There is
> also a convenient **Core AI debug gauge** which shows you **streaming Core AI activity while your
> app is running in Xcode**. This is a great place to **spot performance issues before jumping into
> instruments**."*

That last clause is the practical rule: **triage in the gauge, confirm in Instruments, diagnose in
the Debugger.** The gauge costs nothing, the trace costs a run, and the Debugger costs a
specialization plus a reference run. Do not start at the expensive end.

---

## 2. The debug gauge

The gauge is the cheap first look. It is a row in Xcode's **Debug navigator**, next to CPU, Memory
and Energy Impact, and it streams Core AI activity while your app runs under the debugger.

### 2.1 Getting it to appear — and the failure mode when it doesn't

> ✅ **VERIFIED** — Apple documentation, *Monitoring model performance with the debug gauge*
> (`/documentation/coreai/monitoring-model-performance-with-the-debug-gauge`), NOTE, verbatim:
> *"**The gauge only appears in projects that link the Core AI framework. The gauge does not support
> the Core ML framework.**"*
>
> and the recovery instruction, verbatim:
> *"If you don't see the gauge, verify that your project **directly links** the Core AI framework. To
> check, go to your project settings in the Xcode Navigator and scroll to **Frameworks, Libraries,
> and Embedded Content** in the **General** section. If you don't see the Core AI framework, add it,
> then build and run your project again."*

The screenshot alt-text on that page confirms the setting the docs are describing: `CoreAI.framework`
set to **Always Used**.

> ⚠️ **SILENT FAILURE — a transitively-linked framework produces a missing gauge, not a warning.**
> This is the most likely way you meet the gauge for the first time: you don't. Almost every real
> Core AI adoption goes through a Swift package — `CoreAILanguageModels`, `CoreAISegmentation`, your
> own wrapper — and a package that links `CoreAI.framework` links it for *itself*. Your app target's
> **Frameworks, Libraries, and Embedded Content** list may not mention Core AI at all, the app runs
> perfectly, inference happens, and the Debug navigator simply has no Core AI row. Nothing is logged.
> There is no "gauge unavailable" state to notice; there is only an absence, which reads identically
> to "my model never ran". **Before concluding that no Core AI activity is happening, add
> `CoreAI.framework` to the app target's General ▸ Frameworks list explicitly and rebuild.** The
> extra link is free — the framework is already loaded in your process — and it is the difference
> between a live gauge and a blind spot.

### 2.2 What the tray row shows

The collapsed row in the navigator is a sparkline plus a summary number.

> ✅ **VERIFIED** — same article, verbatim:
> *"Vertical bars appear in the graph, where **each bar represents the combined Core AI events that
> occur within a one-second interval**. The horizontal axis shows time and the vertical axis shows
> the total duration of each combined event. Next to the bars, a label summarizes the **median**
> duration across all events combined."*

Alt-text from the article's screenshots pins down the units: the row reads **`0 µs/event`** before
any inference runs, and **`10 ms per event`** once the model is working. So a gauge sitting at zero
after you have pressed the button is itself a finding — either the framework is only transitively
linked (§2.1) or your inference path never executed.

### 2.3 The three event types

> ✅ **VERIFIED** — same article, verbatim:
> *"At the top, three separate metrics show the **median** duration for each event type:*
> - ***Inference**: A single, complete inference from the model. **Primary event type.** Appears in
>   **blue** in both the metrics and graph.*
> - ***Load**: Preparation of the model for loading into memory. Appears in **green** in both the
>   metrics and graph.*
> - ***Specialization**: Runtime specialization of the model for the target device architecture.
>   **This only appears for models that aren't specialized ahead of time.** Appears in **orange** in
>   both the metrics and graph."*

Three event types, and **three different aggregations in one UI** — which is easy to misread:

| Where | What the number means |
|---|---|
| Metric label at the top | **median** duration for that event type |
| Tray sparkline bar | **total/combined** duration of all events in that one-second bucket |
| Per-type graph bar | **maximum** event duration within that one-second interval |

> ✅ **VERIFIED** — same article, on the per-type graphs: *"Each graph displays data for a single
> event type. **Each bar represents the maximum activity duration within a one-second interval.**"*
> with statistics **High** (maximum event duration), **Low** (minimum event duration) and **Count**
> (number of events).

If you are comparing "the gauge said 10 ms" against "Instruments said 31 ms", check which of those
three you are reading before you file a bug.

### 2.4 The activity table

> ✅ **VERIFIED** — same article, the four columns, verbatim:
> - ***Start**: Start time of the event. Uses `hh:mm:ss.sss` format, **relative to start time of
>   first event received**.*
> - ***Duration**: Total duration of event. **Units change dynamically depending on time scale.***
> - ***Model**: Name of the model that produced the event. **Matches the model's filename.***
> - ***Event**: Type of event. Either a Load, Inference, or Specialization event.*

Two behaviours worth knowing before you fight the UI:

> ✅ **VERIFIED** — same article: *"The table shows events from oldest to newest. **Scroll to the
> bottom to turn on automatic scrolling**, which always shows the latest events. To examine a specific
> row, scroll up to turn off automatic scrolling."*
> and: *"The activity graphs and the table are interactive… click it, and the table selects the
> corresponding events… You can also select events in the table, and the charts highlight the
> corresponding bars."*

The **Model** column matching the filename is the reason to give your assets meaningful names. In a
bundle with three assets — `vision.aimodel`, `embed.aimodel`, `model.aimodel` for a VLM — the gauge
is the fastest way to see which of the three is eating the wall clock, and it costs you nothing but
naming discipline at export time.

### 2.5 The More menu — and the footgun that makes it useless

Each event row has a **More** menu. It has exactly two items:

> ✅ **VERIFIED** — same article, verbatim:
> *"The options available are:*
> - ***Open in Core AI Debugger**: Opens the external Core AI Debugger to inspect model structure and
>   intermediate values.*
> - ***Export to file**: Saves the input values for this inference to a file for later inspection."*

> ⚠️ **SILENT FAILURE — the More menu is retroactively unavailable, and nothing tells you why.**
> Apple's own NOTE, verbatim: *"**Open the report page before triggering the event you want to
> investigate. The More button options aren't available for events recorded before the report was
> open.**"*
>
> The failure shape is nasty because it is invisible: you run the app, you reproduce the bad
> inference, you go looking for the row, and the menu items are simply not there. There is no
> disabled state with an explanation, no log line, no alert. The instinct is to conclude that the
> hand-off feature doesn't work, or that this build of Xcode is broken. It isn't — the gauge only
> retains the material needed for hand-off from the moment its report page is frontmost. **Practical
> rule: open the Core AI gauge's report page as step one of any debugging session, before you touch
> the app.** If you have already reproduced the bug, you have to reproduce it again.

### 2.6 Export to file: the only route to the real input tensors

> ✅ **VERIFIED** — same article, verbatim: *"Choose **Export to file** to save the input tensors for
> the selected Inference event. A save dialog appears, letting you choose where to store the file.
> **Single-tensor inputs save as `.npy` files; multi-tensor inputs save as zipped `.npz` files.**"*

and the claim that makes the gauge structurally important rather than merely convenient:

> ✅ **VERIFIED** — same article, verbatim: *"The debug gauge provides **the only entry point to a
> live Core AI Debugger session, and the only way to capture the input tensors that produced a
> specific Inference event**."*

Read that twice. Every other path into the Debugger starts from an `.aimodel` and *synthetic* inputs
— zeros, ones, random, or a NumPy file you made earlier (§8.1). The gauge is how you get the tensors
that your app, on that device, with that camera frame and that tokenizer state, actually handed to
the model at the moment the output was wrong. That is often the entire difference between a
reproducible bug and an unreproducible one.

This matters more than it sounds because of a finding from the community side of the corpus:

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md`, the zoo's
> authoring notes (`compute-units-and-authoring.md:135-136`), verbatim: *"**Localize divergence with
> REAL inputs** — degenerate constant-input probes lie (they said an ANE chunk was exact when real
> inputs showed it diverged from layer 1)."*
>
> Single-author community material, self-declared uncontrolled conditions. But it is a specific,
> falsifiable claim about a specific failure, and it aligns exactly with why Apple built an export
> button. Treat the direction as sound and the numbers as unaudited.

A useful shape for the exported file:

```python
# Reading what the gauge exported. Nothing Core AI-specific — it is plain NumPy.
import numpy as np
from pathlib import Path

path = Path("~/Desktop/inference-inputs.npz").expanduser()

if path.suffix == ".npy":
    tensors = {"input": np.load(path)}
else:                                    # .npz — one entry per model input
    with np.load(path) as archive:
        tensors = {name: archive[name] for name in archive.files}

for name, array in tensors.items():
    print(f"{name}: shape={array.shape} dtype={array.dtype} "
          f"min={array.min():.4f} max={array.max():.4f} "
          f"nan={np.isnan(array).any()} inf={np.isinf(array).any()}")
```

Two things that check out immediately from this and nowhere else: the **dtype the runtime actually
delivered** (fp16 when you assumed fp32 is a classic), and whether a NaN or Inf entered the model
rather than being produced by it. If the input already contains NaN, no amount of sync-point
analysis inside the model will help — the bug is in your preprocessing.

### 2.7 Handing off

> ✅ **VERIFIED** — same article: *"Start profiling in Instruments by clicking the **Profile in
> Instruments** button in the top-right corner of the gauge's report page."*

So the gauge is a hub: **Profile in Instruments** at the top right for the timing question,
**More ▸ Open in Core AI Debugger** on a row for the numerics question.

> 🔴 **GAP — the gauge's pre-release naming leaked, which tells you how young this is.** The
> article's own screenshot alt-text shows the context menu reading *"**Open in DebugML…** and Export
> to file…"* while the body prose says "Open in Core AI Debugger". `DebugML` was evidently the
> internal codename. Harmless, but it means **the exact menu strings in the Xcode 27 build you have
> may differ from the documentation**, and nobody in this corpus has run the gauge to confirm which
> spelling shipped. **Safe default:** navigate by position (the More button on an event row) rather
> than by string, and don't script against these labels.

### 2.8 What to look for in the gauge, concretely

The gauge is coarse, so use it for coarse questions. Three that it answers well:

1. **Are there Specialization events at all after the first launch?** Specialization only appears
   for models that aren't specialized ahead of time — and, once specialized, results are cached. A
   Specialization event on *every* launch means the cache is missing every time. The two usual
   causes: `SpecializationOptions` differing between calls (the cache key is the source asset URL
   *plus* the options, and `SpecializationOptions` is `Hashable`, so a different value is a different
   entry), or an OS update having invalidated the cache. Part 7 reference 02 covers the cache
   contract; the gauge is how you notice you are violating it.
2. **Are Load events happening repeatedly?** They should occur once per model per process.
3. **Is the median inference duration what you predicted?** If it is 5× your expectation, stop and
   take a trace — you are probably on the wrong compute unit, and only the Instruments template can
   tell you that.

> 🔴 **GAP — whether the gauge requires a scheme option, and what it costs.** Apple's article says
> "build and run your project" and nothing more, which reads as automatic. Whether the gauge imposes
> measurable overhead on inference, and whether there is a scheme toggle to disable it, is not
> documented anywhere in this corpus. **Resolution:** an Xcode 27 install and an A/B measurement of
> the same inference loop with and without the debugger attached. **Safe default meanwhile:** treat
> gauge numbers as debug-build numbers, never as ship-quality benchmarks — take those from a Release
> build with the debugger detached, as you would for any other Xcode gauge.

---

## 3. The Core AI instrument

The instrument is where the timing question gets answered properly: which compute unit, how long,
how often, and — crucially — *in what shape over time*.

### 3.1 Recording a trace

> ✅ **VERIFIED** — Apple documentation, *Analyzing model runtime performance with Instruments*
> (`/documentation/coreai/analyzing-model-runtime-performance-with-instruments`), verbatim:
> *"Select your app's scheme and a run destination, then choose **Product > Profile**. In the
> Instruments template picker, select the **Core AI** template and click the **Choose** button.
> Alternatively, open Instruments and choose the Core AI template."*

The template picker's own description string, from the article's screenshot alt-text:
**"Core AI: Monitors an application's machine learning activity executed through Core AI."**

Note the difference from the Foundation Models workflow of the 2025 cycle, where you picked the
**Blank** template and added the instrument by hand with `+`. Core AI ships a **named template**, so
you pick it directly. If you have muscle memory from Part 5's Foundation Models material, this is
the one step that differs.

And Apple's two hygiene NOTEs, both verbatim, both worth obeying:

> ✅ **VERIFIED**: *"Profile on a **real device** for the most accurate performance data."*
> ✅ **VERIFIED**: *"For the most actionable results, **run your app on its own. Other apps competing
> for CPU, GPU, or Neural Engine resources can distort the trace.**"*

The second is not boilerplate for this stack. The Neural Engine is a single shared resource, and a
background app doing Vision work will serialize against yours in a way that shows up as inflated
inference intervals with no cause visible anywhere in your own timeline.

### 3.2 The four instruments in the template

The Core AI template is not one instrument, it is four. This list was dropped by the usual docs
mirror and had to be recovered from Apple's raw DocC JSON, so it is worth reproducing in full:

> ✅ **VERIFIED** — same article, `termList` recovered from Apple's raw DocC JSON, verbatim:
> - ***Core AI*** — *"Captures timing information for activity in the Core AI framework across all
>   four event categories (Specialization, Load, Setup, and Inference)."*
> - ***Neural Engine*** — *"Captures activity on the Neural Engine, so you can correlate Core AI
>   events with the hardware that runs them."*
> - ***GPU*** — *"Captures and shows activity on the GPU during the trace."*
> - ***Time Profiler*** — *"Profiles running threads on all cores at regular intervals for all
>   processes."*

> ✅ **SDK-verified, 2026-07-29** — that four-instrument composition is now confirmed from the
> shipped toolchain, not just DocC prose. The Xcode 27.0 beta's
> `Instruments.app/Contents/Resources/templates/Core AI.tracetemplate` archives exactly four
> instrument identifiers — **`com.apple.dt.instruments.coreai`**, **`com.apple.ane`** (Neural
> Engine), **`com.apple.xray.instrument-type.metal-gpu`**, and
> **`com.apple.xray.instrument-type.coresampler2`** (the Time Profiler sampler) — plus the template
> description *"Monitors an application's machine learning activity executed through Core AI."*
> `xcrun xctrace list templates` lists **Core AI** and `list instruments` lists **Core AI** and
> **Neural Engine** by name.

That composition is the answer to the most common Core AI question — *"did my model actually run on
the Neural Engine?"* You do not answer it by reading `SpecializationOptions`; you answer it by
looking at whether the Neural Engine instrument shows activity aligned with your Inference events.
`preferredComputeUnitKind` is a **preference**, not a lock:

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md` citing the
> optional `coreai-models` Swift runtime (`CoreAIShared/Runtime/ModelStructure.swift:57-66`): that helper probes the
> model's **structure** and derives a preference — a chunked, static-shape model prefers
> `.neuralEngine`; a single dynamic `main` prefers `.gpu` with `expectFrequentReshapes`. The
> conclusion drawn there: *"So 'iOS ⇒ ANE' is the default tendency, not a guarantee. The axis is
> **structure, not literally iOS**."* Community reading of Apple source; the file and line are
> checkable, the inference about routing is theirs. Direct `AIModel` callers are not governed by
> this package’s naming policy.[^sample-routing-policy]

Which is precisely why the template ships a Neural Engine lane. Believe the trace, not the option.

### 3.3 The track hierarchy

> ✅ **VERIFIED** — same article, verbatim: *"The Core AI instrument divides model activity into
> multiple tracks. The **top track shows all activity. Expand it to reveal a child track for each
> active model, and expand a model's track to reveal a child track for each of its active
> functions.**"*
> NOTE, verbatim: *"The default function name is `main`."*

Three levels: **all activity → per model → per function**. That third level is the one that pays for
itself on a multi-entrypoint asset. If you followed session 325's advice and split SAM3 into
`image_encode` / `text_encode` / `detect` — three entrypoints in one asset, converted by staging
three exported programs into one `TorchConverter` — then the instrument gives you one track per
entrypoint, and the 76%-faster-second-inference claim becomes something you can *see*: swap the
prompt, and only the `text_encode` and `detect` tracks light up while `image_encode` stays quiet.

> ✅ **VERIFIED** — the three-entrypoint split is real, shipping code, not a slide:
> `apple/coreai-models`, `python/src/coreai_models/segmentation/pipeline.py:265-286` stages three
> exported programs into one converter with `entrypoint_name="image_encode"`, `"text_encode"` and
> `"detect"`, then calls `to_coreai()` once. Naming convention in the instrument's event labels is
> `model::function`.

### 3.4 The four event categories

Also a dropped `termList`, also recovered from raw DocC JSON, and listed by Apple "in the order they
typically appear":

> ✅ **VERIFIED** — same article, verbatim:
> - ***Specialization*** — *"Runtime specialization of the model for the target device architecture.
>   Only appears for models that aren't specialized ahead of time. Appears in **green** in the
>   timeline."*
> - ***Load*** — *"Preparation of the model for loading into memory. Appears in **cyan** in the
>   timeline."*
> - ***Setup*** — *"Preparation of the model before each inference. Appears in **magenta** in the
>   timeline."*
> - ***Inference*** — *"A single, complete inference from the model. Appears in **blue** in the
>   timeline."*

and the three sentences that tell you what "normal" looks like:

> ✅ **VERIFIED** — same article, verbatim:
> *"**Specialization events are often the most time-intensive operations during model runtime. Each
> model produces at most one Specialization event — none if the model is fully specialized for the
> device or already cached.**"*
> *"Next, brief **Load** events appear in the timeline. They occur **only at the start of runtime**,
> when your app first loads the model into memory. **If you see frequent Load events during runtime,
> check that your app doesn't reload models repeatedly.**"*
> *"Finally, brief **Setup** events appear in the timeline, and Inference events follow. **A Setup
> event precedes each inference.**"*

So the healthy shape of a trace is: at most one green block, one short cyan block, then a repeating
magenta-blue pair per inference. Any deviation is a named bug:

| Deviation | What it means |
|---|---|
| Green Specialization block on every launch | cache is missing — options changed between calls, or OS update invalidated it |
| Cyan Load events sprinkled through the run | your app is reloading the model; hold the `AIModel` |
| Magenta Setup growing relative to blue Inference | per-inference preparation is dominating; suspect reshapes/re-allocation |
| Blue Inference intervals widening monotonically | the §4 problem — no KV cache, or a cache that isn't being used |

> ⚠️ **SILENT FAILURE — colour intuition does not transfer between the two tools, and will make you
> misread a trace.** The gauge has **three** event types; the instrument has **four** (it adds
> **Setup**). And two of the shared three have **swapped colours**:
>
> | Event | Debug gauge | Core AI instrument |
> |---|---|---|
> | Inference | blue | blue |
> | Load | **green** | **cyan** |
> | Specialization | **orange** | **green** |
> | Setup | *(absent)* | magenta |
>
> Both mappings are quoted verbatim from Apple's own two articles above; this is not a
> transcription error on our side. The practical consequence: a developer who has spent an afternoon
> in the gauge learning "green = Load" opens Instruments, sees a big green block, and reads it as a
> model reload when it is a **specialization** — the opposite diagnosis, with the opposite fix.
> Nothing warns you, because a colour cannot be wrong. **Read the category name in the event label,
> never the colour, when you switch tools.**
>
> 🔴 **GAP — why the gauge omits `Setup` is unknown.** If `Setup` is folded into the gauge's
> Inference measurement, gauge inference medians are inflated relative to Instruments by the Setup
> cost; if it is simply not captured, the two numbers measure different things. Nothing in the
> corpus says which. **Resolution:** one app, one model, both tools, compare medians. **Safe default
> meanwhile:** never compare a gauge number to an Instruments number as though they were the same
> measurement.

### 3.5 Recognising the UI: the event labels Apple's own screenshots show

Because nobody here has run the template, the most useful thing available is the set of literal
strings visible in Apple's documentation screenshots. These are what you will actually see in the
timeline, and they are more specific than any prose description:

> ✅ **VERIFIED** — labels and timings read from the article's screenshot alt-text:
>
> | Category | Event label seen | Notes |
> |---|---|---|
> | Specialization | **`Compile Asset, Specialize`** with a nested **`Compile segment`** sub-event | example duration ≈ **800 ms** (00:13.000 → ≈00:13.800) |
> | Load | **`Load model::main (10.54 μs)`** | microseconds — Load is genuinely cheap |
> | Setup | **`Setup for model::main (66.96 μs)`** with nested **`Context.alloc (22.83 μs)`** | Setup has children too |
> | Inference | **`Run main`**, and **`Run streaming function func_19`** | |
>
> Hardware tracks in the same example trace: `Neural Engine`, `GPU (M3 Max)`,
> `Time Profiler / CPU Usage`, `M3 Max Metal Device State`.

Two inferences worth drawing from those strings, both of which change how you read a trace:

1. **Specialization events have internal structure.** `Compile Asset, Specialize` containing
   `Compile segment` is the nesting session 326 described as "a model load event with a large
   sub-event for specialization" (§5). Expand it.
2. **Specialized graphs get auto-generated sub-function names.** `Run streaming function func_19` is
   not a function you wrote. Do not go looking for `func_19` in your Python — it is a product of
   specialization. If your model has a single `main` entrypoint and the trace shows several
   `func_NN` runs per inference, that is the specializer having split your graph, not a bug.

> 🔴 **GAP — the on-screen lane and metric names in the Instruments UI are not confirmed by anyone
> in this corpus.** Everything in §3.2–§3.5 comes from Apple's documentation prose, two `termList`s
> recovered from raw DocC JSON, and screenshot alt-text. That is good evidence for *what exists* —
> four instruments, four categories, three levels of track, these event-label formats — and weak
> evidence for *what the strings look like on screen* in the Xcode 27 build you have. **Nobody here
> has run Xcode 27's Instruments.** In particular: the detail-pane column set, whether there is a
> per-compute-unit breakdown column for each Inference event, whether the template works against the
> Simulator, and whether there is a cache-hit metric are all **unknown**.
>
> **Narrowed 2026-07-29:** the template file itself was inspected in the Xcode 27.0 beta and its
> four-instrument composition is now ✅ (see §3.2) — so *what exists* is settled. The on-screen
> strings remain out of reach from the toolchain alone: Instruments streams instrument definitions
> from the **recording target** at attach time (a sweep of the host Instruments.app finds none of
> the known lane names), so no amount of host-side inspection produces them.
> **Narrowed again 2026-07-31:** an OS 27 recording target now exists on this machine — the iOS
> 27.0 Simulator runtime — but `xcrun xctrace record` against the booted simulator hangs for every
> template on this macOS 26.5 host (measured with a Time Profiler control; `--no-prompt` set), so
> headless capture is ruled out. Note also that **Core AI itself cannot run in the simulator** (the
> CoreAI module is absent from the iPhoneSimulator27.0 SDK — guide 7.1), so even a GUI recording of
> *this* template against the simulator would show the lane chrome but no Core AI events.
> **Resolution:** one manual GUI Instruments recording — against the booted iOS 27.0 simulator for
> the lane/metric *names*, or a real OS 27 device for names *and* live Core AI events. **Safe default meanwhile:** navigate by the four
> category names above (they are Apple's own, and appear in event labels, not just legends), expand
> every track to its function level, and do not script or automate against any string in the UI.

---

## 4. Worked trace 1 — inference intervals that grow

This is the single best "reading a Core AI trace" example Apple has published, because it is the
only one where the same app is traced **before and after** a fix.

### 4.1 The symptom, in the app

> ✅ **VERIFIED** — WWDC26 session 324, *Meet Core AI* (Ben), lines 99–108, verbatim:
> *"Now with this put together I'm going to try a test run with both snakes powered by the AI model
> to see how it does. Running it shows that the model is working. However, I see that **the game is
> getting slower as it goes on**.
> Alongside the Core AI framework, there's a **new instrument in Xcode** to help you profile the Core
> AI models running in your app.
> In this case I've ran the app with Instruments and I can see the **inference intervals getting
> notably larger over time**, which means the inference calls are increasing in latency.
> This makes sense because **transformer models have quadratic time complexity with respect to the
> sequence length**. And in our game the sequence length is increasing with every move the model
> makes."*

The app is a Snake game where both players are driven by a small transformer that takes the game
history as a sequence. Every move lengthens the sequence. The trace signature is the important part:
**the blue Inference blocks in the timeline get wider, monotonically, from left to right.** Not
noisy, not spiky — a curve.

That shape is diagnostic. Three different problems produce three different shapes:

| Trace shape (Inference lane) | Likely cause |
|---|---|
| Widening monotonically with each call | growing sequence length with no KV cache — this section |
| Flat, but each block much wider than expected | wrong compute unit, or an unfused op — check the Neural Engine / GPU lanes |
| Flat with periodic spikes | reallocation or reshape per N calls — check `Setup` and `expectFrequentReshapes` |
| Wide first call, flat after | normal warm-up; the first call includes on-device JIT work |

### 4.2 The mechanism, and Apple's word for the fix

> ✅ **VERIFIED** — session 324, lines 107–112, verbatim:
> *"Each time the input sequence is increased, the transformer model **recomputes a set of internal
> key and value embeddings for every element in the sequence**. A common strategy used to improve the
> performance of decoding loops like this when using transformers is to **cache keys and values**
> that are computed for each element in the sequence, as opposed to re-computing them all from
> scratch with each inference.
> This can be achieved through Core AI by using **states**.
> **States are inputs to the model which are both read, and updated in-place during inference.**
> By introducing the key and value caches as states on the model, we both avoid recomputing them on
> each inference, and also **remove the need to provide the full history of the game as an input**
> since the data needed from older steps are stored in the states.
> So after the first input, each subsequent step uses the cache for history and only takes the new
> features of the latest board state."*

Two wins in one change, and the second is the one people forget: states shrink the **input**, not
just the compute. The model stops taking the whole history.

### 4.3 The Python side — `register_buffer` plus in-place mutation

> ✅ **VERIFIED** — session 324, lines 113–119, verbatim:
> *"First I'll update the torch module by adding key and value cache tensors as **buffers** within
> the transformer module, by using the **torch `register_buffer` API**. This will later result in
> these tensors being **mutable buffers in the exported torch program which Core AI will convert to
> states**. Then in the forward function of the module, I'll add the logic to actually use the
> caches. This involves **reading previous features keys and values out of the cache**. Then
> **writing the computed keys and values for the new features back into the cache**. Lastly, I'll
> rerun the same code from before to re-convert the model, but now adding in the **`state_names`
> argument to the convert call** to specify the names of the new state arguments."*

The mechanism — a registered buffer that the `forward` mutates in place becomes a Core AI state — is
verified against the converter's own test suite, not reconstructed:

> ✅ **VERIFIED** — `apple/coreai-torch`, `tests/test_stateful.py:58-64`, verbatim:
>
> ```python
> class _BufMutate(nn.Module):
>     def __init__(self) -> None:
>         super().__init__()
>         self.register_buffer("state", torch.zeros(1, 4))
>
>     def forward(self, x: Tensor) -> Tensor:
>         self.state.copy_(x)
>         return self.state
> ```
>
> and the IR that results (`tests/test_stateful.py:88-95`, verbatim FileCheck lines):
>
> ```
> // CHECK-NEXT:   coreai.graph @main(%{{.*}}: tensor<1x4xf32> {MutableBuffers.buffer_mutation = "b_state", coreai.name = "b_state"}, …
> ```
>
> — the buffer became a graph input annotated `MutableBuffers.buffer_mutation`. That annotation *is*
> the state.

The full conversion call, with `state_names`:

> ✅ **VERIFIED** — `TorchConverter.add_exported_program` signature, from
> `apple/coreai-torch` `docs/api/TorchConverter.md`:
>
> ```python
> def add_exported_program(
>     self,
>     exported_program: ExportedProgram,
>     input_names: Sequence[str] | None = None,
>     output_names: Sequence[str] | None = None,
>     state_names: Sequence[str] | None = None,
>     entrypoint_name: str = "main",
> ) -> TorchConverter          # returns self, chainable
> ```

```python
# The re-conversion, after adding the caches. Nothing here is Instruments-specific —
# but the shape of the trace in §4.5 is a direct consequence of it.
import torch
from coreai_torch import TorchConverter, get_decomp_table

exported = torch.export.export(model.eval(), args=example_input)
exported = exported.run_decompositions(get_decomp_table())   # required; see Part 8

program = (
    TorchConverter()
    .add_exported_program(
        exported,
        input_names=["features"],                       # non-stateful args ONLY
        output_names=["logits"],                        # return values ONLY, not mutations
        state_names=["key_cache", "value_cache"],       # the new part
    )
    .to_coreai()
)
program.optimize()                                      # in-place; return value unused
asset = program.save_asset(Path("snake.aimodel"))
```

Three contract details that bite, all verified from the converter's docs and `_utils.py`:

> ✅ **VERIFIED** — `docs/api/TorchConverter.md` and `coreai_torch/_utils.py:1700-1856`:
> - `input_names` covers **non-stateful user inputs only**; `output_names` covers **return values
>   only, not mutation outputs**. Both are documented as **breaking changes** from earlier
>   pre-release behaviour where they covered all graph inputs/outputs.
> - `state_names` must have **exactly one entry per graph state**, or the converter raises with a
>   count mismatch message.
> - Ordering is **buffers in registration order, then mutated user inputs in signature order** — and
>   the converter's own docstring warns it *"cannot detect silent reordering"*. That is the
>   converter telling you, in writing, that it will happily build you a model whose caches are
>   swapped.

> ⚠️ **SILENT FAILURE — a state you did not intend, from an in-place mutation you forgot.** The
> converter treats **two** things as state: buffers you registered and mutate, *and* **user inputs
> mutated in place inside `forward()`** — `x.mul_(2)` on a `forward` argument. Both are detected from
> the exported program's graph signature, and Apple's documentation is explicit that there is **no
> flag** to opt a mutated user input out of state. So a stray `.mul_()`, `.add_()` or `.copy_()` on
> an argument silently turns an *input* into a *state*, changing your function's signature: the
> caller must now supply a mutable view for it, and if they don't, the run fails at a call site far
> from the cause. **The fix is in the model, not the converter:** clone first
> (`x_local = x.clone(); x_local.mul_(2)`) or use the out-of-place form (`x_scaled = x * 2`).

### 4.4 The Swift side — `MutableViews` and `consume`

> ✅ **VERIFIED** — session 324, lines 120–127, verbatim:
> *"To start, I'll update the ModelPlayer to **store the key and value cache NDArrays** which will be
> the state arguments passed to each inference. I'll initialize them with the expected shape for the
> transformer. In this case I converted the model such that it expects the key and value caches to
> always be a **fixed size for a maximum possible context length**. Then when it's time to run
> inference, I'll construct a **collection of MutableViews** containing both views of the key and
> value caches. Then provide those as the **`states` argument of the `InferenceFunction.run`
> method**. Now the caches will be both read and updated in-place during each inference."*

The exact call shape is verified against Apple's shipping Swift package, not reconstructed from the
narration:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `swift/Sources/CoreAILanguageModels/InferenceEngines/CoreAISequentialEngine.swift:275-291`,
> verbatim:
>
> ```swift
> // Build states (KV cache — persistent, inout)
> var states = InferenceFunction.MutableViews()
> states.insert(&keyCache, for: keyCacheName)
> states.insert(&valueCache, for: valueCacheName)
>
> // Build output backings (logits — written in-place)
> var outputViews = InferenceFunction.MutableViews()
> outputViews.insert(&logitsArray, for: logitsName)
>
> // Execute
> _ = try await function.run(
>     inputs: [inputIdsName: inputIdsArray, positionIdsName: positionIds],
>     states: consume states,
>     outputViews: consume outputViews
> )
> ```
>
> So: `InferenceFunction.run(inputs:states:outputViews:) async throws`, with a non-escapable
> `InferenceFunction.MutableViews` built by `insert(_ array: inout NDArray, for name: String)` and
> passed with Swift's `consume` operator. When a function has no states, Apple's own code passes an
> **empty** `InferenceFunction.MutableViews()` rather than omitting the argument
> (`SpeechModel.swift:81`).

Two rules the runtime enforces and the compiler does not explain kindly:

- **You must supply a mutable view for *every* state.** Omitting one is an error. There is no
  `stateCount` property; use `descriptor.stateNames.count`.
- **`consume`d views cannot be reused.** Rebuild the `MutableViews` collection each call. The
  `NDArray`s themselves persist — that is the whole point — but the collection does not.

### 4.5 The after-trace, and the hedge in it

> ✅ **VERIFIED** — session 324, lines 128–130, verbatim:
> *"Now with the updated model, I'll re-run the app. This time I can see it **maintains a steady
> speed, no longer slowing down overtime**. When tracing the updated app in Instruments, I can
> confirm that the **inference latency is growing at a much slower rate**."*

Read the last five words carefully. Apple did **not** say the latency became constant, and you
should not expect a flat Inference lane after adding states. With a fixed-size cache and a growing
attention window, per-step attention cost still grows — **linearly instead of quadratically**. The
trace goes from a curve to a gentle ramp, not to a flat line. If your after-trace is flat, either
your sequence is not actually growing or something else is dominating.

Two costs the fix buys that trace, worth stating so nobody is surprised:

- **Memory up-front.** The caches are allocated for the **maximum possible context length**, once,
  at init. That is a deliberate memory-for-latency trade. Apple's own `CoreAILanguageModel` exposes
  the choice as a `kvCacheStrategy` parameter with `.auto` (documented as a 256-token initial size
  for dynamic models) and `.fixedSize` (pre-allocate at full `maxContextLength`) —
  ✅ verified from the doc comment on `CoreAILanguageModel.init(resourcesAt:mode:variant:kvCacheStrategy:)`.
- **Prefix reuse is not universal.** ⚠️ Community-measured (`notes/repos/john-rocky-models.md`):
  trimming a KV cache is a single integer assignment and is worth up to **101×** on turn-2
  time-to-first-token at 4k context — but `trimKVCache` returns `-1` (unsupported) whenever
  `extraStates` is non-empty, because SSM / gated-delta state is a running scan and cannot be
  rewound positionally. Linear-attention and hybrid architectures therefore re-prefill every turn.
  That is a *model-selection* consequence, covered in Part 3; it is mentioned here because it is
  visible in exactly this lane of exactly this trace.

### 4.6 What this teaches about reading traces generally

The reason this example is worth memorising is that **the fix was invisible in the average**. The
mean inference time across the session was unremarkable; the *slope* was the bug. Neither the gauge's
median metric nor a single-number benchmark would have surfaced it. Instruments' value here is not
precision — it is that a timeline has a shape, and shapes carry diagnoses that summary statistics
destroy.

Corollary for your own measurement harness: when you benchmark a decoding loop, **report the
per-step series or at least first/median/last**, never just the mean. A community-side rule from the
zoo makes the same point from the other direction:

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md`, the zoo's
> porting document: measure with an env-gated headless self-test entrypoint that runs **1 cold + N
> warm** passes and writes a result file, because *"Numbers measured through a chat UI are not
> comparable to anything."* Also: report **load time and steady-state throughput separately**,
> because the first call includes JIT specialization. Single-author community material with
> self-declared uncontrolled conditions — but the methodology point stands on its own.

---

## 5. Worked trace 2 — a specialization sub-event in an interactive flow

The second published trace is shorter but the diagnosis is bigger: it changed the app's entire
deployment architecture.

### 5.1 The symptom

> ✅ **VERIFIED** — WWDC26 session 326, *Integrate on-device AI models into your app using Core AI*
> (Carina), lines 119–140, verbatim:
> *"Now let's see it in action. I'll take a photo… and we're waiting. **The segmentation hasn't come
> back yet, so we can't get to card generation. Something is clearly slow here.**
> I know from my code that **I show this spinner when I'm first instantiating my SAM 3 model and
> sending it a prompt**. Let's see what's going on.
> **I took a trace with the new Core AI instruments, and sure enough there's a model load event right
> at that point, with a large sub-event for specialization.**
> **Specialization is the process that prepares a Core AI model for execution on device.** When your
> model is loaded it is checked to see if it has already been specialized and cached. **This process
> can take a significant amount of time for very large models.** That is what we were seeing in our
> instrument trace.
> While future loads are from the cache and are fast, **that first time is something I need to plan
> for**.
> **Having that happen right in the middle of the user experience is... probably not great.**"*

**The signature to look for: a model load event with a large nested specialization sub-event.** In
the documented UI vocabulary from §3.5 that is a `Compile Asset, Specialize` block containing a
`Compile segment` child — Apple's own screenshot shows one at roughly **800 ms**, and that is a
*small* model by 2026 standards. A multi-gigabyte asset is seconds.

Note the causal chain the presenter walked, because it is the reusable part:

```
"the spinner never ends"                      ← user-visible symptom
   → "I show this spinner when instantiating"  ← correlate symptom to code path
   → take a trace, look at that timestamp      ← the instrument's actual job
   → Load event with a Specialization child    ← the finding
   → "that's a first-launch cost, not a bug"   ← the reclassification
   → change WHEN it happens, not HOW FAST      ← the fix
```

The instrument did not make anything faster. It reclassified a performance bug as a **scheduling**
problem, which has a completely different set of solutions.

### 5.2 Why specialization is expensive, and what AOT actually removes

> ✅ **VERIFIED** — session 326, lines 155–158, verbatim:
> *"During specialization the model goes through two main transformations. First it goes through a
> core set of compilation steps. Second, executable artifacts are generated. These artifacts are tied
> to the device and OS version they were generated on. Of these two steps, compilation is the most
> expensive and takes the most amount of time.
> The Core AI toolchain lets me do **some of that compilation ahead-of-time on my development
> machine**, producing a compiled version of the model. While that compiled model **still needs to be
> specialized for the specific user's device**, there is now much less work to do and finishes
> significantly faster."*

> ✅ **VERIFIED** — Apple documentation, *Compiling Core AI models ahead of time*, the residual-work
> warning, verbatim: *"**Even with ahead-of-time compilation, the compiled asset still requires some
> specialization on the device.** The amount of compilation that remains depends on the model and
> the compute units it uses."*

So in your after-trace, the green Specialization block **shrinks**; it does not vanish. If you adopt
AOT and see zero specialization events, you are looking at a cache hit from a previous run, not at
the effect of AOT. Delete the cache entry and re-measure.

The command, verbatim from the docs:

```shell
% xcrun coreai-build compile MyModel.aimodel --platform iOS --min-deployment-version 27.0 --output compiled/
```

✅ VERIFIED flags: `compile` (subcommand), `--platform`, `--min-deployment-version`, `--output`,
`--preferred-compute`. Apple's prose additionally alludes to a target-architecture option without
naming it: *"For the available values, the minimum deployment version, the target architecture, and
other options, run `coreai-build compile --help`."*

> ✅ **GAP — RESOLVED 2026-07-31 — the full `coreai-build compile` flag list; the architecture-code
> *set* is enumerated, its device mapping is not.** `xcrun coreai-build compile --help` has now been
> run: the wrapper turned out to ship in the optional **Metal Toolchain component**
> (`xcodebuild -downloadComponent MetalToolchain`), not in Xcode-beta.app — which is why the
> 2026-07-29 check found it absent and only the `aimodelc` stub (command types `package`/`compile`,
> no `--help`, binary saying *"Please use 'xcrun coreai-build' instead"*) in the app bundle. Full
> capture: `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`, `coreai-build 3600.79.1`. The
> flag list: `--output`, `--platform {iOS, macOS, watchOS, visionOS, tvOS}`,
> `--min-deployment-version` (default 27.0), `--preferred-compute {gpu, neural-engine, none}`
> (default `none`), `--architecture` (repeatable), `--expect-frequent-reshapes`. Subcommands:
> `compile`, `package`, **`inspect`** (the community claim §15 could only attest from bug reports
> is real — flags `--io/--metadata/--storage/--compute/--ops/--json`) and a previously-unknown
> **`metadata`**. Probing the compiler's own `--architecture` validation enumerated **24 valid
> codes, `h11p…h18p`** (capture file, final section) — `h18p` confirmed valid. What is *still*
> community-reported only: which physical device maps to which code (`h18p` = iPhone 17 Pro from
> `iPhone18,1`, `h16c` = M4 Max).
> **Safe default unchanged:** discover the architecture string at runtime rather than hardcoding it:
>
> ```swift
> let arch = AIModel.deviceArchitectureName          // ✅ SDK-verified: static, returns String
> let assetName = "MyModel.\(arch).aimodelc"         //    (CoreAIDelegates-27.0:107-112)
> ```

And the hardware gate that neither transcript mentions and that will decide whether AOT is even
relevant to your install base:

> ✅ **VERIFIED** — Apple documentation, *Compiling Core AI models ahead of time*, NOTE, verbatim:
> *"Ahead-of-time compilation **only compiles for devices that support Apple Intelligence**,
> including **iPhone or iPad with the A17 Pro chipset or later, a Mac with the M1 chipset or later,
> or Apple Vision Pro with the M2 chipset or later.**"*
>
> Older devices get no `.aimodelc` and fall back to full on-device specialization from `.aimodel`.
> Your trace on an A16 iPhone will therefore look like the *before* trace no matter what you ship.

### 5.3 The fix Apple chose, and the two it rejected

> ✅ **VERIFIED** — session 326, lines 138–139, verbatim:
> *"So when should I do it? **I could kick it off at launch or run it in the background but that
> feels wasteful if the user isn't even interested in this feature yet. I think a better idea is to
> create a dedicated first-run experience, where I can move this work to happen while the user is
> learning about the feature for the first time. This keeps model loading and specialization out of
> the interactive flow.**"*

Both rejected alternatives are the ones most teams reach for first, so it is worth recording *why*
they were rejected: at-launch specialization taxes every user including the ones who never use the
feature, and background specialization does the same work at an unpredictable time. The chosen shape
is: **feature-introduction screen → explicit opt-in button → Background Assets download → then
specialize, behind explanatory UI.**

And the corroborating headline recommendation from the other session:

> ✅ **VERIFIED** — session 324, line 147, verbatim: *"**It is recommended you avoid having model
> specialization occur within user interactive flows.**"*

The download half of the decision came from a number the presenter checked, not from a principle:

> ✅ **VERIFIED** — session 326, lines 145–146, verbatim: *"I'd been assuming the models would just be
> bundled with the app and when I checked, **they're adding over 1 GB to my download size. That hits
> everyone who updates, even people who'll never touch this feature.**"*

### 5.4 Turning the trace into a gate you can check

The useful engineering output of this section is not "use Background Assets" — it is a **checkable
property of a trace**. Write it down as an acceptance criterion:

> **On a device that has never run this feature, the Core AI instrument must show the Specialization
> event inside the feature-introduction screen's lifetime, not inside any screen the user reached by
> tapping a primary action.**

That is falsifiable from a single trace, it survives refactors, and it is the kind of thing that
regresses silently when somebody moves a model load into a view initialiser.

The runtime API that lets you *branch* on the same fact, without a trace:

> ✅ **VERIFIED** — session 324, lines 149–152, plus Apple's *Managing model specialization and
> caching* article: check the cache first with `AIModelCache.default.model(for:options:)`; a `nil`
> result means the model is not specialized and you are about to pay for it. Gate your UI on that.
>
> ⚠️ Two cache contract details that produce phantom re-specialization: the cache key is
> **(source asset URL, `SpecializationOptions`)**, and `SpecializationOptions` is `Hashable` — so
> changing options between calls creates a **second** entry rather than reusing the first, doubling
> both storage and specialization cost. And an **OS update always invalidates the cache**, regardless
> of policy. Both show up in a trace as a green Specialization block where you expected none.

### 5.5 The measured payoff, attributed

> ✅ **VERIFIED, Apple-published, but qualitative** — session 326, lines 171–176: after adopting AOT,
> *"the model preparation step should be a fraction of what it was before"*, and *"on subsequent
> inferences, we are using the cached model asset so the user experience is seamless."* No numbers
> were given on stage for the specialization delta, and none appear in the documentation. The only
> hard figure adjacent to this demo is the **"over 1 GB"** bundled-model download size quoted above.

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md`: *"On-device JIT
> specialization of a big static graph stalls or gets killed; roughly **≥ 1 GB means AOT**, ≤ ~50 MB
> JITs fine, in between try it."* The same source notes the `.aimodelc` is roughly **2× the
> `.aimodel` size** because it embeds the precompiled graph. Single-author, uncontrolled conditions,
> macOS 27 beta era — but the ≥1 GB threshold is the only quantitative guidance of its kind anywhere
> in the corpus, and it is consistent with Apple's qualitative "very large models" language.

> ⚠️ **Loud community warning worth repeating verbatim** — same source: *"**Never execute an
> iOS-compiled bundle on a Mac.** It can wedge the GPU/ANE stack and take the whole machine down
> (watchdog reboot). Mac bundles on Mac, iOS bundles on device."* Community-reported, not
> Apple-documented. Cheap to respect.

---

## 6. Core AI Debugger — the workspace

Everything before this section was about *time*. Everything after it is about *numbers*.

### 6.1 What it is and where to get it

> ✅ **VERIFIED** — WWDC26 session 325, *Dive into Core AI model authoring and optimization*
> (Nicole), lines 107–108, verbatim:
> *"Core AI Debugger is a **new standalone application** that can help you inspect your models on
> Apple platforms. With the debugger you can:*
> 1. *visualize your model's structure in an easy-to-understand **graph format**,*
> 2. *execute your model on **specific hardware** for **true runtime results**, and*
> 3. *validate **inference correctness against a reference run** — all in one place."*

> ✅ **VERIFIED** — `https://developer.apple.com/core-ai-debugger/`, the download page:
> *"Core AI Debugger bridges the gap between modeling and deployment. It allows you to visualize,
> run, and validate Core AI models across every Apple platform with actionable feedback built for
> fast iteration."*
>
> **System requirements, verbatim from the page:**
> - Host machine: **macOS 27 or later**
> - Paired devices: **iOS 27 or later, iPadOS 27 or later, or macOS 27 or later**
>
> ⚠️ Note what is *absent* from the paired-device list: **visionOS, tvOS and watchOS**, even though
> the Core AI framework itself is available on all seven platforms. Distribution is a signed-in
> download (Apple Account, free registration, developer agreement); it is **not** bundled with Xcode.

> 🔴 **GAP — whether the Debugger can attach to visionOS / tvOS / watchOS devices at all.** The
> download page lists three paired-device platforms; the framework supports seven. Whether the
> omission is a limitation, a beta gap, or an oversight in the page is unknown. **Resolution:** try
> it with a paired Vision Pro on macOS 27. **Safe default meanwhile:** if you ship Core AI on
> visionOS, plan to do numeric validation on a Mac target of the same asset (the `.aimodel` is
> portable) and treat visionOS-specific numeric divergence as unvalidatable by this tool.

### 6.2 The three-step workflow

> ✅ **VERIFIED** — Apple documentation, *Inspecting Core AI models with Core AI Debugger*
> (`/documentation/coreai/inspecting-core-ai-models-with-core-ai-debugger`), verbatim:
> *"Core AI Debugger is a standalone app for inspecting a Core AI model asset (`.aimodel`). The
> debugger follows a **three-step workflow: visualize, execute, and validate.** You visualize the
> model first to understand its structure, then execute the model to produce tensor outputs for each
> operation, and finally compare those outputs against a reference run to validate correctness."*

Those three steps map exactly onto §6–§8 (visualize), §8 (execute) and §9–§11 (validate). They are
also, usefully, three separate levels of cost: visualizing needs only the file, executing needs a
paired device, validating needs a Python reference run.

### 6.3 The four panes

> ✅ **VERIFIED** — same article, verbatim:
> *"The Core AI Debugger workspace includes a **Navigator** panel on the left, **Structure** and
> **Source Viewers** in the middle, and an **Inspector** to the right.*
> - *Use the Navigator to explore, sort, and filter model operations.*
> - *The Structure Viewer shows a graphical representation of the model as a series of connected
>   operations, while the Source Viewer shows the model's original Python source code, alongside a
>   structured module hierarchy.*
> - *Use the Inspector to see detailed metadata about the selected operation, including its
>   description, inputs, and outputs."*
> *"**The workspace stays synchronized around the selected operation**, so you can move fluidly
> between structure, source, and execution details."*

The session narration adds what each pane is *for*, which is more useful than what it contains:

> ✅ **VERIFIED** — session 325, lines 110–119:
>
> | Pane | Position | What it gives you |
> |---|---|---|
> | **Navigator** | left | *"a structured list of operations in the model"*, **grouped by their PyTorch module** |
> | **Structure viewer** | top middle | the graph — *"operation connectivity, execution order, and data dependencies"* |
> | **Source viewer** | bottom middle | *"I'm always grounded in my model's original Python code **down to the specific line**"* |
> | **Inspector** | right | per-op *"description, and additional details on the operation's inputs and outputs"* |
>
> and the payoff sentence, line 119, verbatim: *"Together, these views allow you to move fluidly
> between **graph structure, source code, and execution details**, which **dramatically reduces the
> cognitive overhead of debugging complex models like SAM3**."*

Flow to open one: open the `.aimodel` → click **Inspect** → the workspace opens.

### 6.4 Visualization, in Apple's own words

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*, verbatim:
> *"Opening an `.aimodel` file loads the model's operations, structure, and source. **Operations in
> the Navigator are organized by their PyTorch module.** Selecting a module highlights the
> corresponding operations in the Structure Viewer, revealing their connectivity, data dependencies,
> and execution order. Clicking a specific operation highlights its Python source line in the Source
> Viewer. The Inspector shows additional details about the selected operation, including tensor
> formats of its inputs and outputs."*

Note what this gets you **before** you run anything: connectivity, execution order, data
dependencies, and input/output tensor *formats*. That is enough to answer a large class of questions
— "did my externalized RMSNorm survive as a composite op or get decomposed into fifteen primitives?",
"is this branch even reachable?", "why is there a transpose here?" — without a device, without
inputs, and without specialization.

### 6.5 The bidirectional trick that makes it usable on a big model

> ✅ **VERIFIED** — session 325, lines 113–114, verbatim:
> *"These operations are grouped by their PyTorch module, which is **especially powerful for larger
> models like SAM3** and allows you to navigate your model in a way that feels familiar.
> Selecting a PyTorch module in the navigator, like the **detector decoder**, will **highlight all of
> the corresponding nodes** in the structure viewer."*

Module → nodes, and node → source line. On an 848M-parameter model with 32 transformer layers, this
is the difference between a graph you can reason about and a wall of boxes. It is also the mechanism
the whole §11 diagnosis runs on: "the low-similarity operations all belong to the same module" is
only a *visible* fact because the tool groups by module.

---

## 7. Why the Navigator can group by PyTorch module

This is the causal link back to Part 8, and it is worth spelling out because it is the reason
everything in §6 works — and, in §15, the reason a whole generation of assets stopped loading.

### 7.1 The converter records it, on purpose, by default

Grouping by PyTorch module is not inference. The Debugger is not guessing from op names. The
information was **written into the asset at conversion time** by `coreai-torch`, and it is on by
default:

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/converter.py`, the converter's own
> docstring:
>
> ```python
> class TorchConverter:
>     class Mode(Enum):
>         """Controls the level of debug information embedded in the converted asset.
>
>         Attributes:
>             RELEASE: Lightweight mode that records only operation IDs without
>                 stack traces.
>             DEBUG: Includes full torch stack traces for comprehensive source
>                 mapping and debugging.
>         """
>         DEBUG = "debug"
>         RELEASE = "release"
>
>     def __init__(self, *, mode: "TorchConverter.Mode" = Mode.DEBUG) -> None:
> ```
>
> `mode` is **keyword-only** and defaults to **`Mode.DEBUG`** — full torch stack traces embedded.
> ⚠️ Note that `docs/api/TorchConverter.md` documents the constructor as a bare `TorchConverter()`
> and never mentions `mode` at all. The parameter is real; the API doc has a gap.

Internally, DEBUG mode configures a debug-info recorder with stack traces on:

> ✅ **VERIFIED** — quoted in `apple/coreai-torch` issue #37, from `converter.py`:
>
> ```python
> debug_config = _DebugInfoRecorder.Config(
>     include_stack_trace=True,
>     options=options,
>     verify_debuginfo_locations=_get_verify_debuginfo_locations_enabled(),
> )
> ```

and the module hierarchy is recorded with a specific, checkable naming convention:

> ✅ **VERIFIED** — `apple/coreai-torch`, `_get_module_hierarchy(node, registry)` returns entries
> shaped `"<ClassName>$<per-type instance count>"` — `"Linear$1"`, `"Block$2"` — outermost-first.
> Repeated calls to the **same** submodule instance reuse the same count.
> `tests/test_get_module_hierarchy.py` asserts ≥2 distinct `Block$n` and ≥3 distinct `Linear$n` for
> a model that calls `self.block(x)` twice.

You can see the same call stack in a compiler error message, which is the most concrete evidence
that this metadata is really in the IR (this is from the incident in §15, but the *shape* is the
point):

```
loc(fused<{call_stack = ["PixelShuffle$1", "Upsampler$1", "Sequential$19", "EDSR$1"],
  identifiers = ["pixel_shuffle"]}>[...]): error: …
```

`PixelShuffle$1 → Upsampler$1 → Sequential$19 → EDSR$1` — that is exactly the tree the Navigator
draws, serialized into an MLIR location.

### 7.2 Which means the Source Viewer has a hard prerequisite

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*, verbatim:
> *"The source-level features, including source line and PyTorch module mappings, **require debug
> metadata embedded in the `.aimodel` at export time**. Without this operation-level metadata, you
> can still view model operations in the Navigator, Structure Viewer, and the Inspector, but **the
> Source Viewer is unavailable**."*

> ⚠️ **SILENT FAILURE — three of four panes work perfectly without debug metadata, so a
> `RELEASE`-converted asset looks like a working Debugger session with a broken feature.** You open
> the model, the Navigator lists operations, the Structure Viewer draws the graph, the Inspector
> shows shapes and dtypes — everything you would expect a debugger to do. The Source Viewer is
> simply not there. There is no "this asset was converted in RELEASE mode" banner, because the tool
> genuinely cannot tell the difference between "converted without debug info" and "converted from
> something that wasn't PyTorch". The natural conclusion is that source mapping is broken, or beta,
> or unavailable for your model type. It isn't; your asset just doesn't carry the data.
>
> **How to tell, and what to do:** if the Source Viewer is missing, re-convert with the default
> `TorchConverter()` (DEBUG mode) rather than `TorchConverter(mode=TorchConverter.Mode.RELEASE)`,
> and make sure nothing in your pipeline calls `strip_debug_info` (§15). Keep a debug-converted
> asset next to your shipping asset for exactly this purpose — they are the same graph, and only
> one of them is debuggable.

### 7.3 The preview-era environment variables

There is a second, easier-to-miss way to end up without metadata:

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/debugging.md:5-13`, verbatim:
> *"During the current preview, set the following environment variables to ensure **operation-level
> debug metadata is preserved** and available to these tools:"*
>
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```
>
> Apple's Debugger article points at this same page for "how to export your model with debug
> metadata". A third variable exists and is off by default:
> **`VERIFY_DEBUGINFO_LOCATIONS`** (accepts `true|1|yes|on`), read by
> `_get_verify_debuginfo_locations_enabled()`, documented as disabled *"for performance reasons"*.

`USE_LOCAL_COREAI` has a second, independent purpose worth knowing because it explains a confusing
crash: `coreai-optimization`'s own `Makefile` exports `USE_LOCAL_COREAI ?= 1` with the comment that
it tells the runtime to *"skip the symbol-version check against the host's installed
`/System/Library/Frameworks/CoreAI.framework`… without this, importing `coreai_torch` aborts at
dlopen time with a Swift `Symbol not found` error"* (✅ verified from the Makefile). So on a machine
whose OS is older than the wheel, this variable is not optional at all.

> 🔴 **GAP — how long "the current preview" lasts, and what the shipping default becomes.** These
> two variables are explicitly framed as preview-era. Whether a GA `coreai-torch` preserves
> operation-level debug metadata without them is unstated. **Resolution:** re-read
> `docs/api/debugging.md` at each release; the note is dated by its own wording. **Safe default
> meanwhile:** export both variables in the shell you convert from, unconditionally. They cost
> nothing when unnecessary, and their absence is invisible until you are three panes deep in a
> Debugger session wondering where your source went.

### 7.4 The practical rule

Two assets, one graph:

```python
# Debuggable asset — default DEBUG mode, full stack traces, Source Viewer works.
program_dbg = TorchConverter().add_exported_program(ep, …).to_coreai()
program_dbg.optimize()
program_dbg.save_asset(Path("MyModel.debug.aimodel"))

# Shipping asset — RELEASE mode, op IDs only, smaller.
program_rel = (
    TorchConverter(mode=TorchConverter.Mode.RELEASE)
    .add_exported_program(ep, …)
    .to_coreai()
)
program_rel.optimize()
program_rel.save_asset(Path("MyModel.aimodel"))
```

✅ Both call shapes are verified: `TorchConverter(mode=…)` keyword-only from `converter.py`;
`add_exported_program(...)` chainable returning `self`; `optimize()` called as a bare statement for
its in-place side effect — every example in Apple's repo does it that way and none uses the return
value; `save_asset(path)` returning an `AIModelAsset`, with an optional second positional metadata
argument used by `apple/coreai-models`' own pipeline (`save_asset(asset_path, metadata)`).

Keep the debug asset out of the app bundle and next to your export script. When something goes wrong
in production, you debug the debug asset — it is byte-different but semantically identical, and it is
the only one the Source Viewer can read.

---

## 8. Running the model on a device from the Debugger

Step two of the three-step workflow: **execute**. This is what separates the Debugger from a graph
viewer — it specializes and runs your asset on real hardware and shows you the tensor that came out
of every operation.

### 8.1 The specialization scheme

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*, verbatim:
> *"Configure a **specialization scheme** before executing your model. The scheme settings let you
> specify a **hardware target, compute unit, and model inputs using predefined tensors (zeros, ones,
> or random) or values from a NumPy file.**"*

The dialog's fields, read from the article's screenshot alt-text:

> ✅ **VERIFIED** — screenshot alt-text, same article:
>
> | Field | Example value seen |
> |---|---|
> | **Target** | *"Demo's MacBook Pro"* |
> | **Function** | `main` |
> | **Compute Units** | *"Prefer GPU"*, *"Default"* |
> | **Graph Visualization** | *"Specialized"* |
> | **Inputs** (one row per input) | `pixel_values`, `input_ids`, `attention_mask`, each configurable as *"NumPy Array"* |
> | Buttons | **Cancel** / **Run** |

and the narration of the same dialog:

> ✅ **VERIFIED** — session 325, lines 120–129, verbatim:
> *"I'll **pick my Mac from the list of targets**, then specify the inputs I want to provide to the
> model. Starting with the **pixel values**, then the **input_IDs**, and the **attention_mask**."*
> …click **Run**… *"SAM3 is now being **specialized** to run on my device."*
> *"the structure viewer has updated to show me the model, **exactly as it would run on my Mac**."*
> *"I can now **click on any operation to see its output tensor directly in the inspector. Without
> needing to modify anything.**"*
> *"In the inspector, I'll click on the **tensor preview** to get a closer look at the mask."*

The three input names in that demo (`pixel_values`, `input_ids`, `attention_mask`) match the
Hugging Face `Sam3Model` signature and the input names in Apple's shipped
`coreai_models/segmentation/pipeline.py` — a small but reassuring cross-check that the demo was run
on the real shipping export.

> ✅ **VERIFIED** — same article, verbatim: *"Clicking Run **specializes the model for the selected
> target**, optimizing it for that hardware's capabilities. **The Structure Viewer updates to show
> the specialized model exactly as it executes on the chosen device.**"*
> *"After running, click any operation in the Navigator or Structure Viewer to see its **output
> tensor** directly in the Inspector."*

### 8.2 Why "Graph Visualization: Specialized" is the most important field in that dialog

The Structure Viewer has **two** graphs to show you: the portable graph as converted, and the
specialized graph as it actually executes on the chosen target. They are not the same graph.
Specialization fuses, reorders, splits and re-lays-out operations for the hardware — that is its
entire job. This is the same phenomenon that produces the `Run streaming function func_19` labels in
the Instruments timeline (§3.5).

Consequences for how you read what you see:

- **An operation you wrote may not exist in the specialized graph.** It may have been fused into a
  neighbour. That is not a bug; it is the compiler doing its job. `AIProgram.optimize()` and
  specialization both do this.
- **Operations you never wrote may appear.** Layout conversions, casts, and split sub-functions.
- **Comparing the two views is a real diagnostic.** If a composite op you deliberately externalized
  (an `sdpa`, an `rms_norm`) is present in the unspecialized graph but scattered into primitives in
  the specialized one, your fast-kernel path did not engage.

> ⚠️ **SILENT FAILURE — `AIProgram.optimize()` can delete operations that carry meaning.** The
> series carries this one from Part 8: `optimize()` is a mandatory in-place pass driver, and it will
> remove axis manipulations it considers redundant — including ones that were doing
> broadcasting-significant work. Nothing throws; the graph gets smaller and the numbers get wrong.
> The Debugger's specialized-vs-unspecialized comparison, and `coreai_torch.debugging.graph_diff`
> (§13.5), are the two tools that make such a deletion visible at all. If a model was correct before
> `optimize()` and wrong after, diff the two graphs before you start bisecting tensors.

> 🔴 **GAP — the full list of values for `Target`, `Compute Units` and `Graph Visualization` in the
> scheme dialog.** We have exactly four observed strings: one target (a MacBook Pro), two compute-unit
> values (*"Prefer GPU"*, *"Default"*), one graph-visualization value (*"Specialized"*). Whether the
> compute-unit menu mirrors `ComputeUnitKind` (`.cpu`, `.gpu`, `.neuralEngine`) exactly, whether
> there is a CPU-only entry corresponding to `SpecializationOptions.cpuOnly`, and whether
> "Unspecialized" or "Converted" is the other Graph Visualization value are all **unknown**.
> **Resolution:** open the app on macOS 27 and read the menus. **Safe default meanwhile:** run first
> with **Default** compute units to establish a baseline, then change exactly one field at a time —
> which is also what a comparison session is for (§9.4).

### 8.3 Inputs: predefined tensors versus real ones

The scheme dialog offers zeros, ones, random, or a NumPy file. Prefer the NumPy file, for a reason
already stated in §2.6 and worth repeating because it is the most common way to waste an afternoon:

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md`: degenerate
> constant-input probes reported an ANE chunk as numerically exact when real inputs showed it
> diverging from layer 1. Single-author community material; the mechanism is obvious enough
> (constants annihilate whole classes of numerical error) that the direction is credible regardless.

Which is why the gauge's **Export to file** (§2.6) is the highest-value 20 seconds in this whole
workflow: it produces exactly the `.npy` / `.npz` that this dialog wants, containing exactly the
tensors that produced the bad output on the device.

The end-to-end loop, then, is:

```
app misbehaves on device
  → gauge report page open BEFORE reproducing (§2.5)
  → reproduce → find the Inference row → More ▸ Export to file  → inputs.npz
  → Core AI Debugger ▸ open the .aimodel ▸ scheme settings
      Target = that device, Inputs = inputs.npz, Compute Units = Default
  → Run  → click the suspicious operation → read its output tensor
```

Nothing in that loop requires modifying your app, adding logging, or recompiling the model — which
is the specific claim session 325 makes: *"I can now click on any operation to see its output tensor
directly in the inspector. **Without needing to modify anything.**"*

---

## 9. `save_intermediates` and the reference run

Step three: **validate**. Executing tells you what your model computes; it does not tell you whether
that is *right*. For that you need something to compare against, and the something is a PyTorch run.

### 9.1 Why a reference run is the right shape of answer

> ✅ **VERIFIED** — Apple documentation, *Validating inference correctness against a reference run*
> (`/documentation/coreai/validating-inference-correctness-against-a-reference-run`), verbatim:
> *"**Quantization and model specialization can introduce numerical drift** between a Core AI model
> and the original source model. Core AI Debugger pairs each operation in your Core AI asset with its
> counterpart in a reference run, then automatically measures similarity for every matched pair."*

Note the two named causes: **quantization** and **specialization**. The second surprises people —
specialization alone, with no compression at all, can move numbers, because fusing operations changes
accumulation order and layout changes change precision behaviour. A model that is bit-identical to
PyTorch on CPU and visibly different on the ANE has not necessarily got a bug in it.

### 9.2 The file

> ✅ **VERIFIED** — same article, verbatim:
> *"An `.aimodelintermediates` file **records the intermediate tensor values produced at each
> operation of a PyTorch reference run**. To generate the file, use the `save_intermediates` API,
> **passing both the model you want to validate and the original source model**. The result is a
> per-operation mapping between the PyTorch run and the Core AI model that Core AI Debugger can use
> to compare inference results."*

and the session narration that introduces it as new:

> ✅ **VERIFIED** — session 325, lines 134–137, verbatim:
> *"I'll return to my notebook and use the **NEW save intermediates API**. This API **executes a
> PyTorch model and captures intermediate tensor values at each operation**. I want to compare my
> quantized results with the baseline Sachin showed earlier, so **I'll pass in the int4 model
> alongside the original SAM3**."*

### 9.3 The actual signature

The prose above is loose about which model goes where. The source is not:

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/debugging/torch_utils.py:905-913`, verbatim:
>
> ```python
> def save_intermediates(  # noqa: PLR0913
>     program: ExportedProgram,
>     inputs: Union[tuple[Any, ...], list[Any]],
>     output_dir: Union[str, Path],
>     node_filter: Callable[[torch.fx.Node, Any], bool] = _default_node_filter,
>     coreai_program: AIProgram | None = None,
>     enable_autocast: bool = False,
>     model_name: str = "main",
> ) -> str:
> ```
>
> Parameter semantics, verbatim from the docstring:
> - `program` — *"ExportedProgram to execute and inspect."*
> - `node_filter` — *"callable that takes `(node: torch.fx.Node, result: Any)` and returns True if
>   the node's value should be dumped."*
> - `coreai_program` — *"Optional `AIProgram` to extract source info from. If provided, **variable
>   information from source locations will be added to the metadata**."*
> - `enable_autocast` — *"Whether to enable automatic mixed precision during execution. Default is
>   False. **Set to True to handle mixed precision models and avoid dtype mismatch errors.** Uses CPU
>   for autocast operations."*
> - `model_name` — *"Creates a directory named **`{model_name}.aimodelintermediates`** within the
>   specified `output_dir`."*
> - **Returns:** *"Path to the generated metadata JSON file."*
>
> Companion loader, ✅ verified from the same module:
> ```python
> def load_intermediates(metadata_path: str | Path,
>                        device: str | torch.device | None = None) -> DebugTrace
> ```
> `DebugTrace` exposes `.inputs`, `.outputs`, `.intermediates` (all dicts keyed by node name).

So the roles are unambiguous at the code level even though the prose is not: **`program` is the
model that gets executed**, and **`coreai_program` is only a source of mapping metadata** — it is not
run.

> 🟡 **RECONSTRUCTED — which model to put in `program`.** Apple's prose says *"passing both the model
> you want to validate and the original source model"*; the session says *"pass in the int4 model
> alongside the original SAM3"*. Neither states which is executed. The docstring settles that
> `program` is executed and `coreai_program` supplies mappings, so the only real question is which
> PyTorch model you want as the **reference**. For the SAM3 diagnosis in §11 the reference must be
> the **uncompressed** model, because the entire point is measuring how far the int4 asset drifted
> from baseline. **Safe default:** `program` = the exported program of the *uncompressed* model;
> `coreai_program` = the `AIProgram` you are debugging (so node names line up). If you want the
> opposite comparison — "did compression alone, before conversion, break it?" — generate a second
> intermediates file from the *compressed* PyTorch model and compare the two in PyTorch, not in the
> Debugger.

### 9.4 Generating one

```python
# Produce the reference run the Core AI Debugger will load as Configuration B.
# Requires coreai-torch >= 0.4.1. Set USE_LOCAL_COREAI=1 and ENABLE_DEBUG_INFO=1
# in the shell before running (see §7.3).
from pathlib import Path

import torch
from coreai_torch import TorchConverter, get_decomp_table
from coreai_torch.debugging.torch_utils import save_intermediates, load_intermediates

model = build_reference_model().eval()          # the UNCOMPRESSED baseline
example_input = (torch.randn(1, 3, 336, 336),)

exported = torch.export.export(model, args=example_input)
exported = exported.run_decompositions(get_decomp_table())

# The AIProgram you actually intend to debug — supplies name/source mappings only.
program = TorchConverter().add_exported_program(
    exported_program_of_the_asset_you_are_debugging,
    input_names=["pixel_values"],
    output_names=["pred_masks"],
).to_coreai()
program.optimize()

metadata_path = save_intermediates(
    program=exported,                 # executed
    inputs=example_input,
    output_dir=Path("./debug_output"),
    coreai_program=program,           # mapping metadata only
    enable_autocast=False,            # True if your model is genuinely mixed-precision
    model_name="main",                # → ./debug_output/main.aimodelintermediates
)
print(metadata_path)                  # → …/main.aimodelintermediates/metadata.json
```

On-disk layout, ✅ verified: a **directory** named `{model_name}.aimodelintermediates` inside
`output_dir`, containing NumPy files for the tensors plus a `metadata.json` whose top-level keys are
`"inputs"`, `"outputs"` and `"intermediates"` — plus `"mappings"` when `coreai_program` was supplied.

Two trip hazards, both verified:

> ✅ **VERIFIED** — `load_intermediates` validates the directory suffix. A path not ending in
> `.aimodelintermediates` raises *"Expected a `.aimodelintermediates` directory, but got: …"*. It
> accepts either the directory or the `metadata.json` path inside it.
>
> ✅ **VERIFIED** — some docstring examples in the source still call the function
> **`dump_intermediates`**. That is a stale name. The exported symbol is **`save_intermediates`**.

### 9.5 Filtering, because a whole model is a lot of tensors

`node_filter` exists because dumping every intermediate of an 848M-parameter model is not a thing you
want to do casually.

> ✅ **VERIFIED** — `apple/coreai-torch`, `docs/api/debugging.md`, verbatim example:
>
> ```python
> def custom_filter(node, result):
>     """Only save convolution and linear layer outputs"""
>     return any(op in str(node.target).lower() for op in ["conv", "linear", "matmul"])
>
> metadata_path = save_intermediates(
>     program=exported_program, inputs=example_input,
>     output_dir=Path("./debug_output"), node_filter=custom_filter,
> )
> ```

Practical filters, in ascending order of how much you already know:

| Filter | When |
|---|---|
| default (`_default_node_filter`) | first pass, small model |
| weight-bearing ops only (`conv`/`linear`/`matmul`) | quantization drift — those are the ops you compressed |
| one module's prefix | you already suspect a module, e.g. from §11 |
| normalization + attention outputs | fp16 overflow hunting |

### 9.6 Reading a reference run without the GUI

The same file is useful in a notebook, and this is often faster than opening the app:

```python
trace = load_intermediates(Path("./debug_output/main.aimodelintermediates"))

print(f"inputs:        {list(trace.inputs.keys())}")
print(f"outputs:       {list(trace.outputs.keys())}")
print(f"intermediates: {len(trace.intermediates)} operations")

for node_name, tensor in trace.intermediates.items():
    if not torch.isfinite(tensor).all():
        print(f"NON-FINITE at {node_name}: shape {tuple(tensor.shape)}")
```

✅ The `.inputs` / `.outputs` / `.intermediates` access pattern and the printing idiom are verbatim
from Apple's `docs/api/debugging.md`. The finiteness check is ours; a NaN in the **reference** run
means you are about to spend a day chasing a divergence that exists in PyTorch too.

---

## 10. Sync points and the five similarity metrics

This is the concept the Debugger is built around, and it is the reason the tool is worth downloading.

### 10.1 What a sync point is

> ✅ **VERIFIED** — session 325, line 145, verbatim:
> *"These pairs are called **sync points**, places where the specialized model's output is **expected
> to match** the original PyTorch result. **The debugger automatically identifies these points
> throughout the model** to make the comparison process easy."*

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*, verbatim:
> *"Core AI Debugger compares two inference runs using ***sync points*: operation pairs whose outputs
> are expected to match.** When a comparison session starts, the debugger **automatically identifies
> sync points and computes similarity metrics for each one** so you can pinpoint where inference
> diverges."*

The word "expected" is doing real work. Not every operation in a specialized graph has a counterpart
in the PyTorch graph — fusion and layout changes destroy the one-to-one correspondence. A sync point
is a pair the debugger has *matched*, and the set of sync points is smaller than the set of
operations. That is a feature: it is precisely the set of places where a mismatch is meaningful
rather than an artefact of compilation.

### 10.2 Starting a comparison session

> ✅ **VERIFIED** — *Validating inference correctness against a reference run*, the six steps,
> verbatim:
> 1. *"Open your `.aimodel` file in Core AI Debugger."*
> 2. *"In the toolbar, click the **Comparison** button to start a comparison session."*
> 3. *"Under **Configuration A**, set the **Target, Function, Compute Unit, and Graph
>    Visualization**, and specify your model inputs."*
> 4. *"Under **Configuration B**, click the **Target** menu and select **Intermediates File** under
>    **Load Reference Run**."*
> 5. *"Click the folder icon and select your `.aimodelintermediates` file."*
> 6. *"Click **Compare**."*
> NOTE: *"You can return to single-session mode at any time by clicking the Comparison button."*

Configuration B does not have to be a reference run. Apple documents **two** comparison
configurations, and they answer different questions:

> ✅ **VERIFIED** — *Inspecting Core AI models with Core AI Debugger*, verbatim:
> - *"**Validate against a reference run.** Run your model in PyTorch and export the intermediate
>   tensor values to an `aimodelintermediates` file using the `coreai-torch` API. Open that file
>   alongside your `.aimodel` to compare the results."*
> - *"**Validate across configurations.** Configure two runs of the same `.aimodel` to compare
>   execution across **different hardware targets, compute units, or inputs**."*

and the session's phrasing of the second: *"another configuration to compare against **like a
different Target or Compute Unit**"* (325:141).

| You want to know | Configuration A | Configuration B |
|---|---|---|
| Did conversion + quantization drift from PyTorch? | the asset, on your Mac | Intermediates File |
| Does this model behave differently on the ANE than the GPU? | asset, Compute Units = Prefer GPU | asset, Compute Units = default/ANE |
| Does it behave differently on iPhone than on Mac? | asset, Target = Mac | asset, Target = paired iPhone |
| Is this input pathological? | asset, inputs = A | asset, inputs = B |

The cross-configuration mode is the underrated one. It needs **no Python at all** — no reference run,
no `save_intermediates`, no export environment. If your model produces good output on the Mac and bad
output on the phone, that is two configurations of one asset and the debugger will tell you which
operation first disagrees.

### 10.3 What the Navigator shows once a comparison starts

> ✅ **VERIFIED** — session 325, lines 143–150, verbatim:
> *"The navigator is now populated with **operation pairs** which combine an operation from the
> **specialized model** and **PyTorch model**."*
> *"Each sync point is paired with a **metric** indicating how similar the two outputs are which
> makes it **trivial to find where they diverge**."*
> *"**green nodes indicate similar tensors, red nodes would indicate significant differences**"* —
> with intermediate values shown yellow (*"several yellow sync points, which indicates that parts of
> my model have **moderately diverged**"*).

> ✅ **VERIFIED** — *Validating inference correctness against a reference run*, verbatim:
> *"Each sync point shows both operation names alongside a similarity score and a color-coded
> indicator dot:*
> - ***Green**: close match*
> - ***Yellow**: moderate divergence*
> - ***Red**: large error"*
> *"**Sort by Similarity** to identify the most divergent pairs, or **sort by Operation** to see
> whether failures cluster in a specific part of the model."*

Two sorts, two questions. **Sort by Similarity** answers *"what is worst?"*. **Sort by Operation**
answers *"is it localized?"* — and localization is what turns a list of bad numbers into an
actionable change. §11 is the worked case where the answer to the second question was the whole
diagnosis.

Navigation detail from the session, worth stealing: *"I'll use the **up arrow key** to navigate
through the low-PSNR sync points **one-by-one to see if a pattern emerges**"* (325:152), and clicking
a sync point updates the Source Viewer to show *"the operation's **PyTorch module hierarchy**"*
(325:154).

### 10.4 The five metrics

The brief for this guide expected the metric list beyond PSNR to be unknown. It is not: Apple
publishes all five, in a `termList` that the usual documentation mirror drops and that had to be
recovered from the raw DocC JSON.

> ✅ **VERIFIED** — *Validating inference correctness against a reference run*, `termList` recovered
> from Apple's raw DocC JSON, verbatim:
> *"Core AI Debugger reports **five metrics** for each sync point. **Color indicators are
> metric-aware, so green always signals a good result regardless of which metric you choose.** The
> **default metric is PSNR**."*
>
> - **PSNR** — *"The ratio of the reference tensor's peak output value to the mean squared error,
>   expressed in decibels. **A good general-purpose choice** that works well for most models and
>   tensor types."*
> - **Mean Absolute Error (MAE)** — *"The average absolute difference across all elements. Use this
>   to understand overall deviation **without sensitivity to outliers**."*
> - **Mean Squared Error (MSE)** — *"The average squared difference, which **amplifies larger
>   errors**. Useful when large deviations are more consequential than small ones."*
> - **Max Absolute Error** — *"The single largest per-element difference. **A high value can expose
>   clipping or overflow even when MAE looks acceptable.**"*
> - **Mean Relative Error** — *"The average difference as a proportion of the expected value at each
>   element. **Useful when tensor magnitudes vary widely across operations.**"*

The session corroborates the default and the changeability: *"The default metric is a **peak
signal-to-noise ratio or PSNR**, but this **can be changed to whichever similarity indicator suits
your model best**"* (325:148).

"Color indicators are metric-aware" is the sentence that makes the feature usable: green means good
under MAE and green means good under PSNR even though one is small-is-better and the other is
large-is-better. You do not have to reinterpret the colours when you switch metric.

**When to leave PSNR, in practice:**

| Metric | Reach for it when |
|---|---|
| PSNR (default) | anything, first pass; comparable across the whole model |
| Max Absolute Error | you suspect **clipping or overflow** — fp16 saturation, an int8 range that is too tight. MAE hides these; this metric is built to expose them. |
| Mean Relative Error | your activations span orders of magnitude across layers (attention logits vs post-softmax) and a single absolute threshold is meaningless |
| MAE | you want a plain "how far off on average", robust to a couple of bad elements |
| MSE | a few large errors matter more than many small ones — e.g. a detection head where one wrong box is fatal |

### 10.5 Reading a PSNR number — Apple's own bars

The debugger gives you a number. It does not tell you whether that number is acceptable. Apple's
**own agent skill** in `apple/coreai-models` does, and this is the most valuable calibration data in
the corpus for this topic — it is Apple's empirical rulebook, written for a coding agent rather than
for a keynote:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/skills/model-authoring/SKILL.md:94-99`, the
> verification bars:
>
> | Comparison | Bar |
> |---|---|
> | re-authored model vs source | **> 70 dB** |
> | ANE-layout vs GPU-layout | **> 70 dB** |
> | compiled (Core AI) vs torch | **≥ 40 dB** |
> | after 4-bit palettization | **≥ 35 dB** |
>
> and the palettization table (`:149-153`):
>
> | Scheme | Size | Expected PSNR | Flag if |
> |---|---|---|---|
> | 8-bit | ~2× smaller | **> 55 dB** | < 50 dB |
> | 4-bit | ~4× smaller | **~40 dB** | < 35 dB |
> | 2-bit | ~8× smaller | 25–35 dB | *"Usually unacceptable"* |

That table converts the debugger from a curiosity into an instrument. A sync point at 38 dB after
4-bit palettization is **normal**. The same sync point at 38 dB after a *lossless* re-authoring is a
**bug**, because the bar there is 70. The same number means opposite things depending on what you
changed, which is exactly why a raw threshold in your head is worse than useless.

The community-side ladder agrees on the bars and adds an investigation trigger:

> 🟡 **Community-measured, attribute as such** — `notes/repos/john-rocky-models.md`
> (`compute-units-and-authoring.md:129-133`): re-authored vs source (fp16) **> 70 dB**, *investigate
> below 60*; compiled vs torch (fp16) **≥ 40–50 dB**; 4-bit palettized **~40 dB**, *investigate below
> 30*. Single-author community material, self-declared uncontrolled benchmarking conditions — but it
> was written independently of Apple's skill and lands on the same numbers, which is mild
> corroboration for both.

### 10.6 ⚠️ The limit of a similarity metric

> ⚠️ **SILENT FAILURE — an all-green sync-point board can coexist with a model that generates
> different text.** This is the sharpest warning in this guide for anyone shipping an LLM.
>
> Sync points are computed on a **single forward pass**. A language model does not run a single
> forward pass; it runs a decoding loop, and the loop's output at step *t* becomes its input at step
> *t+1*. A per-step error small enough to score 42 dB — comfortably inside Apple's "compiled vs
> torch ≥ 40 dB" bar — can flip one `argmax` at step 12, after which the two models are generating
> **different sequences** and every subsequent comparison is meaningless. Nothing in the debugger
> notices, because the debugger never ran step 12.
>
> The community's stack calls this out explicitly and gates on something else entirely:
>
> > 🟡 **Community-measured** — `notes/repos/john-rocky-models.md`, contrasting Apple's PSNR-based
> > skill with the zoo's own gate: the zoo verifies LLMs with **per-token cosine ≥ 0.999 *and*
> > greedy token-exact match**, and states *"Step 1 looking fine is not a gate; AR drift shows up
> > late."* Its reading of the difference, flagged in the source as the author's own inference and
> > not a claim by either party: *"a **PSNR ≥ 40 dB 'compiled vs torch' pass can coexist with a
> > non-token-exact LLM**, which is the failure the zoo's gate is built to catch."* Also measured
> > there: *"fp16 per-token decode drifts ~5–10 dB / 50 tokens"*, which is the same phenomenon seen
> > from the other side.
>
> **What to do:** treat the debugger's sync points as necessary and not sufficient for autoregressive
> models. Add a decode-level gate to your pipeline — a deterministic prompt, greedy decoding, and a
> token-for-token comparison against the source model — and run it on every conversion. §13 shows the
> Python pieces; the gate itself is your code, and it is thirty lines.

---

## 11. The worked diagnosis — SAM3's missing flower

Everything so far has been apparatus. This is the case it was built for, and it is worth walking
end to end because the reasoning — not the tool — is the transferable part.

### 11.1 The model and where its parameters live

> ✅ **VERIFIED** — session 325, lines 54–63: SAM3 (Segment Anything Model 3) is described as *"an
> 850-million parameter model that performs prompt-based image segmentation"*, structured as an
> **image encoder**, a **text encoder**, and a **detector** (a detection transformer plus mask
> decoder). Line 60, verbatim: *"These two components combined make up **96% of the model's
> parameters** so **getting these right is key**."* Line 158 gives the complement: the detector block
> *"only accounts for **4% of model parameters**"*.
>
> ✅ Cross-checked against `apple/coreai-models`, `models/sam3/README.md`: `facebook/sam3` is
> **848M** parameters (the talk rounds to 850M), exported as three functions — `image_encode`,
> `text_encode`, `detect`.

Hold on to the 96/4 split. It is the entire punchline.

### 11.2 The baseline

> ✅ **VERIFIED** — session 325, lines 81–88, verbatim: *"What I do here is load the baseline
> **32-bit** converted model and run it. As you can see, it's **over 3 gigs** in size."* … *"In this
> image, I ask for a segmentation mask over **all the flowers**. All are successfully detected based
> on the default threshold, running on-device. **This is what I need to preserve after
> compression.**"*

Apple-published, qualitative-with-one-number: **> 3 GB at fp32**, all flowers detected. Note the
discipline — the acceptance criterion was established *before* the compression, on the uncompressed
model, using the actual product behaviour ("all flowers detected"), not a metric.

### 11.3 The compression, in one line

> ✅ **VERIFIED** — session 325, lines 90–95, verbatim: *"`coreai-opt` ships with **preset
> configurations**. `presets.w4` gives me **4-bit per-channel, symmetric quantization in one
> line**."* … *"I set **`ExecutionMode` to `EAGER`, which works great for weight compression. For
> activations, I would use the `GRAPH` mode.**"* … *"Then I initialize `coreai-opt`'s **`Quantizer`**
> with the config, **pass example inputs** and **finalize** — the model is then compressed."*

> ✅ **VERIFIED** — `apple/coreai-optimization`,
> `src/coreai_opt/quantization/config/_presets/quantizer_config.py`, the preset verbatim:
>
> ```python
> def w4(
>     self,
>     *,
>     axis: int | None = None,
>     execution_mode: ExecutionMode = ExecutionMode.GRAPH,
> ) -> QuantizerConfig:
>     """int4 weight-only quantization, per-channel symmetric."""
>     weight_spec = QuantizationSpec(
>         dtype=torch.int4,
>         qscheme=QuantizationScheme.SYMMETRIC,
>         granularity=PerChannelGranularity(axis=axis),
>     )
>     global_config = ModuleQuantizerConfig(
>         op_input_spec=None,
>         op_output_spec=None,
>         op_state_spec={"weight": weight_spec},
>     )
>     return self._owner_cls(global_config=global_config, execution_mode=execution_mode)
> ```

```python
# The compression step, exactly as narrated. Note that execution_mode is a
# keyword argument of the preset — no separate setter call is needed.
from coreai_opt.quantization import Quantizer, QuantizerConfig, ExecutionMode

config = QuantizerConfig.presets.w4(execution_mode=ExecutionMode.EAGER)

quantizer = Quantizer(sam3_wrapper, config)
prepared  = quantizer.prepare(example_inputs)      # tuple
quantized = quantizer.finalize()
```

> ⚠️ **Nuance the talk glosses, verified from the repo.** The transcript recommends `EAGER` for
> weight compression; the repo calls `GRAPH` the *"Recommended default"* and `QuantizerConfig`
> defaults to `ExecutionMode.GRAPH`. Both are right about different things: for weight-only
> compression the two converge and `EAGER` sidesteps the `torch.export` requirement (a real win on a
> model as gnarly as SAM3); for **activation** quantization the graph-mode machinery matters. The
> repo states the consequence plainly (`quantizer.py`, verbatim): *"the total number of fake-quantize
> nodes inserted by graph and eager mode can differ for the same `QuantizerConfig`. This means the
> two modes are **not guaranteed to produce equivalent quantized models**, and final model
> performance (accuracy and latency) may differ between modes even when using identical
> configurations."* Part 9 covers the choice properly.

### 11.4 The failure — and why it is the right kind of failure to teach

> ✅ **VERIFIED** — session 325, lines 96–102, verbatim:
> *"As before, I load the model and run it on-device. The model is now **around 430 megabytes**."*
> *"Look at the result. **One of the occluded flowers is no longer detected.**"*
> *"**I applied the same aggressive compression to every single layer, and it's likely that not every
> layer handles this equally well.** The question is — **which layers are causing this?** This is the
> kind of problem that's **hard to diagnose from the output alone. I need to see inside the model.**"*

Apple-published: **> 3 GB → ~430 MB**, roughly 7×, at the cost of one missed occluded object.

Everything about that failure is characteristic of this stack:

- It **did not throw**. The conversion succeeded, the asset loaded, inference ran, and the output was
  a perfectly well-formed segmentation mask that was missing one object.
- It was **input-dependent**. Not every image would have shown it. An occluded flower is a
  low-confidence detection sitting near a threshold; compression nudged it below.
- It was **invisible in aggregate**. Model size: great. Latency: great. Output: plausible.

> ⚠️ **SILENT FAILURE — compression that succeeds while quietly skipping layers.** Before you blame
> your bit-width, check that the compression you configured actually happened. Two verified
> mechanisms produce assets that are *less* compressed than you believe, both of them log-only:
>
> - **Palettization granularity skips.** `apple/coreai-optimization`'s `_FakePalettizeImplBase.forward`
>   logs *"Tensor incompatible with granularity: … Skipping palettization."* and **disables
>   palettization for that layer** rather than failing. Per-block quantization and
>   per-grouped-channel palettization silently skip any layer whose dimension isn't divisible by the
>   block/group size. ✅ Verified in source; the community note puts it bluntly: *"**Check
>   divisibility before trusting a size.**"*
> - **Diffusion export swallows quantization failures with a warning** —
>   `apple/coreai-models`, `export/compiler.py:69-72`. ✅ Verified.
>
> Both leave you with an asset whose *size* is wrong in the safe direction and whose *behaviour* you
> may have already validated. The tell is arithmetic: compute the expected size from bit-widths and
> compare it to the file. If your 4-bit model is 30% bigger than the formula says, some layers
> didn't take.

### 11.5 The diagnosis

Now the loop from §10:

> ✅ **VERIFIED** — session 325, lines 151–162, verbatim:
> *"I'll **sort by similarity**, and investigate the most dissimilar sync points."*
> *"I'll use the **up arrow key** to navigate through the low-PSNR sync points **one-by-one to see if
> a pattern emerges**."*
> *"I'm noticing that **the vast majority of low-PSNR sync points are actually coming from the
> detector decoder**. This tells me that the quantization scheme applied earlier has **mildly
> corrupted the detector results**. Since we previously identified that **the detector block only
> accounts for 4% of model parameters, we're not getting much benefit from compressing it anyway**.
> So, I'll return to the Jupyter notebook, and try **changing the quantization scheme to ignore the
> detector**."*

Four steps, and the third is the one people skip:

1. **Sort by Similarity.** Find the worst pairs.
2. **Walk them.** Not to fix them — to see whether they have anything in common.
3. **Notice the pattern in module space.** They are all in the detector decoder. This is only
   *visible* because the Source Viewer shows the PyTorch module hierarchy for each sync point (§6.5,
   §7). Apple's documentation states the same investigative rule outright:
   > ✅ **VERIFIED** — *Validating inference correctness against a reference run*, verbatim: *"The
   > module hierarchy at the top of the Source Viewer tells you which PyTorch module the operation
   > belongs to. **If low-similarity sync points cluster in the same module, the divergence is
   > localized there, giving you a precise target for changes to your model.**"*
4. **Cross the pattern with a fact you already knew.** The detector is 4% of parameters. Excluding it
   costs almost nothing in size and removes the entire error cluster. That is a *cost-benefit*
   judgement, not a numerical one, and no tool can make it for you.

Also available in the Inspector while you do this, and worth knowing exists:

> ✅ **VERIFIED** — same article, verbatim: *"In the Inspector, the **tensor outputs from both runs
> are displayed side by side alongside a visual difference**, letting you see directly where the
> values diverge."* Screenshot alt-text describes it concretely: *"three stacked heatmap panels: the
> top panel shows the output from Configuration A, the middle panel shows the **element-wise
> difference with red highlighting** in regions of greatest divergence, and the bottom panel shows
> the output from Configuration B."*

For a spatial model this is the single most informative view in the app: a difference heatmap tells
you whether the error is uniform (a scale problem), edge-localized (a padding or boundary problem),
or concentrated in one region (a semantic problem, e.g. the occluded flower).

### 11.6 The fix

"Ignore the detector" is a **config change**, not a code change, because `coreai-opt` is
config-driven and has an explicit "leave this alone" mechanism.

> ✅ **VERIFIED** — `apple/coreai-optimization`,
> `src/coreai_opt/quantization/config/quantization_config.py:576-582`, verbatim:
> *"The configuration lookup follows a hierarchical precedence (most to least specific):
> 1. `module_name_configs` — Applies to module instances matching a name pattern (**supports regex**)
> 2. `module_type_configs` — Applies to all modules of a specific type
> 3. `global_config` — Default configuration applied to all modules not otherwise configured"*
> and, critically: *"**Setting a config to `None` explicitly disables quantization for that
> scope.**"*

> 🟡 **RECONSTRUCTED — the exact lines Nicole typed are not shown or read aloud.** The mechanism is
> ✅ verified above; the spelling of the pattern is inferred. Written the way the repo's own
> `docs/src/quantization/config.md` writes it:
>
> ```python
> from coreai_opt.quantization import Quantizer, QuantizerConfig, ExecutionMode
>
> config = QuantizerConfig.presets.w4(execution_mode=ExecutionMode.EAGER)
>
> # "Leave the detector alone." None == disabled for this scope.
> config.module_name_configs = {"detector.*": None}          # regex, matched by name
>
> # or, by type:
> # config = QuantizerConfig(module_type_configs={"my_pkg.sam3.DetectorDecoder": None})
> ```
>
> ⚠️ **Verified gotcha for the type form:** *"Keys must be the **fully-qualified Python class
> name** (e.g. `"torch.nn.modules.linear.Linear"`). **Short-form names like `"torch.nn.Linear"` are
> not supported** — the key must match the internal module path exactly."* Get this wrong and your
> exclusion silently matches nothing — the config is accepted, the layer is quantized anyway, and
> your sync points look exactly as bad as before.

### 11.7 The result, and the claim

> ✅ **VERIFIED** — session 325, lines 160–162, verbatim:
> *"Great! I can see that we have **once again reached baseline quality** where all flowers are
> detected and the model is only a fraction of the size! **Core AI Debugger turned hours of manual
> tensor comparison into a visual diagnosis. I started with missing detections and reached a revised
> quantization scheme in minutes.**"*

The final iOS recipe Apple actually ships for this model confirms the lesson stuck, and adds a
detail the talk simplified:

> ✅ **VERIFIED** — `apple/coreai-models`, `models/sam3/README.md`, the shipped per-function recipe:
>
> | Function | Compression |
> |---|---|
> | `image_encode` | 4-bit k-means palettization (group size 32) + fp16 |
> | `text_encode` | **6-bit** k-means palettization (group size 8) + fp16 |
> | `detect` | **fp16, no weight compression** |
>
> ⚠️ Two divergences from the stage narration worth knowing: the talk says *"I apply **4-bit**
> palettization… to **the two encoders**"* (325:241) but the shipped recipe is **asymmetric** — image
> w4/gs32, text w6/gs8. And the talk says *"4-bit palettization **with per-channel scales**"*, while
> the shipped config deliberately sets `enable_per_channel_scale=False`, for a hardware reason stated
> verbatim in `pipeline.py:136-142`: *"`enable_per_channel_scale=True` lowers to `mps.dequantize_lut`
> ops with **rank-6 LUTs, which ANE rejects (max tensor rank 5)**, forcing the runtime to fall back
> to GPU. Keeping it off keeps the asset ANE-compatible at the cost of a small PyTorch-side quality
> regression."* The `detect` function staying uncompressed is the direct descendant of the debugger
> session above.

### 11.8 The transferable procedure

Strip the specifics and this is a method:

1. **Establish the acceptance criterion on the uncompressed model, in product terms.** "All flowers
   detected", not "PSNR > 40".
2. **Compress uniformly first.** It is one line, and it tells you whether you have a problem at all.
3. **When quality drops, do not tune bit-widths.** Find out *where* the error is.
4. **Generate a reference run** from the uncompressed PyTorch model (§9).
5. **Compare, sort by similarity, and look for a module-level pattern** (§10).
6. **Cross the pattern with the parameter budget.** A module that holds 4% of the weights is free to
   exclude; a module that holds 60% is not, and needs a different bit-width rather than an exemption.
7. **Exclude with `None`, re-run, re-check the product criterion.**

Step 6 is why §11.1's 96/4 split was worth remembering, and it generalizes: **before you compress
anything, know your parameter distribution by module.** `ModelInspector` (§12.1) will print it for
you, and it takes about four lines.

---

## 12. `coreai-opt`'s own debugging surface

The Debugger works on a converted `.aimodel`. That is *late*. `coreai-opt` ships its own inspection
and troubleshooting layer that works on the PyTorch model — before export, before conversion, before
you have spent forty minutes on a SAM3 conversion to discover that a config matched nothing.

Four surfaces, one per subsection: the `inspection/` package, and three documentation pages that are
best read as debugging references rather than tutorials.

### 12.1 `ModelInspector` — what will actually be compressed

> ✅ **VERIFIED** — `apple/coreai-optimization`, `src/coreai_opt/inspection/`:
>
> ```python
> from coreai_opt.inspection import ModelInspector
>
> ModelInspector(
>     model: torch.fx.GraphModule | torch.nn.Module,
>     example_inputs: tuple[Any, ...] | None,
>     execution_mode: ExecutionMode,                     # "graph" | "eager"
>     compressor: type[_BaseModelCompressor] | None = None,
>     dynamic_shapes=None,
>     export_with_no_grad: bool = True,
> )
> ```
>
> Methods: `.summary`, `.format_summary(...)`, `.get_matched_ops_for_op_type(op_type)` (exact
> string), `.get_matched_ops_for_op_name(pattern)` (`re.fullmatch`),
> `.get_matched_ops_for_module_name(pattern)` (`re.fullmatch` against each fully-qualified name in
> the op's module stack).
> Exported types: `BoundaryEdge`, `InputEdge`, `ModelInspector`, `ModelSummary`, `ModuleContext`,
> `ModuleInfo`, `OpInfo`, `SourceFrame`.
> `ModuleInfo` mirrors `nn.Module` — `children()`, `named_children()`, `modules()`,
> `named_modules()`, `get_submodule()`, `all_ops()` — plus `input_ops` / `output_ops` boundary dicts.
> `OpInfo` fields: `op_name`, `op_type`, `module_stack`, `inputs`, `outputs`, `is_state`.
> Raises `TypeError` if the model isn't an `nn.Module`, or if it's a `GraphModule` with
> `execution_mode="eager"`. Graph mode requires `compressor ∈ {Quantizer, None}`; eager supports
> `Quantizer` and `KMeansPalettizer`.

The killer method is `get_matched_ops_for_module_name(pattern)`, because it answers the question
§11.6 leaves dangling: **does my exclusion pattern match anything?**

```python
# Before you trust a module_name_configs pattern, prove it matches.
from coreai_opt.inspection import ModelInspector
from coreai_opt.quantization import ExecutionMode, Quantizer

inspector = ModelInspector(
    model=sam3_wrapper,
    example_inputs=(pixel_ref,),
    execution_mode=ExecutionMode.EAGER,   # use the mode you will COMPRESS with
    compressor=Quantizer,
)

matched = inspector.get_matched_ops_for_module_name(r"detector.*")
print(f"{len(matched)} ops matched by 'detector.*'")
for op in matched[:10]:
    print(f"  {op.op_name:40s} {op.op_type:24s} {op.module_stack}")

print(inspector.format_summary())
```

If that prints `0 ops matched`, your §11.6 exclusion would have been a no-op — accepted silently,
quantizing the detector anyway. Two minutes here saves the whole loop.

The summary output has a documented legend:

> ✅ **VERIFIED** — `apple/coreai-optimization`, `docs/src/debugging/model_inspection.md:61-91`,
> verbatim:
>
> ```text
> Legend:
>   ■ module_name (module_type)  ◆ op_name [op_type]
>   op inputs:  {I: producer[N]}   op states: param_name   op outputs: {N: [consumers]}
>   untracked_N  — input tensor whose producer was not intercepted; still quantizable via op_input_spec
>   module inputs:  {I: [op[N], ...]}   module outputs: {I: op[N]}
> ```

> ⚠️ **SILENT FAILURE — op names differ between graph mode and eager mode, so a pattern written
> against the wrong mode matches nothing.** ✅ Verified: graph-mode op names are **global**
> (`linear`, `linear_1`); eager-mode op names are **module-qualified** (`linear1.linear`,
> `linear2.linear`). The repo's own instruction is *"**Use the mode you plan to compress with.**"*
> A regex tuned in a graph-mode inspection and then applied to an eager-mode `Quantizer` silently
> matches zero ops, the `global_config` applies everywhere, and you get the uniform compression you
> were specifically trying to avoid — with no error, no warning, and an asset that is exactly the
> right size.

> 🔴 **GAP — `format_summary`'s keyword arguments.** The docs mention passing `colorize=False`, but
> the signature was not read at source level in this corpus. **Resolution:** `help(ModelInspector.format_summary)`
> in a shell with `coreai-opt` installed. **Safe default meanwhile:** call `format_summary()` with no
> arguments; if you need plain text for a log file, capture stdout rather than relying on a flag
> whose name is unconfirmed.

### 12.2 `debugging/model_inspection.md`

This is the page the legend above comes from. Read it as the reference for the tree format, which is
otherwise cryptic — in particular `untracked_N`, which is documented as *"input tensor whose producer
was not intercepted; still quantizable via `op_input_spec`"*. An `untracked_` entry is not an error;
it is the inspector telling you it could not see where a tensor came from, which happens at module
boundaries and around ops the tracer did not intercept.

### 12.3 `debugging/graph_mode_troubleshooting.md`

> ✅ **VERIFIED** — this document exists: `apple/coreai-optimization`,
> `docs/src/debugging/graph_mode_troubleshooting.md`, added by commit `d1e5d37`
> *"Add graph mode debugging hints and troubleshooting doc (#39)"*.

> 🔴 **GAP — its contents were not read in this corpus.** The file is named in the repository's
> documentation inventory and its introducing commit is identified, but the page body was not
> captured. **Resolution:** `open docs/src/debugging/graph_mode_troubleshooting.md` in a checkout of
> `apple/coreai-optimization`, or read it on `https://apple.github.io/coreai-optimization`.
> **Safe default meanwhile:** the graph-mode failure modes that *are* verified elsewhere in the repo
> are listed below, and they cover the common cases.

What is verified about graph mode, from `src/coreai_opt/quantization/quantizer.py`'s own comparison
table:

> ✅ **VERIFIED**, verbatim:
>
> | Dimension | GRAPH | EAGER |
> |---|---|---|
> | Module fusion | automatic pattern-based fusion (e.g. conv+bn+relu) | manual fusion required |
> | Control flow | static graph only; requires a `torch.export`-compatible model | supports dynamic control flow (if/else, loops) |
> | Shared observer ops | *"ops like MaxPool that share the same observer across inputs and outputs are detected and deduplicated on the graph"* | *"Not supported; ops like MaxPool have independent observers for input vs output, **which can cause incorrect quantization**"* |
> | FQ node dedup | back-to-back fake-quantize nodes collapsed into one | *"No deduplication; … two consecutive FQ nodes are inserted on that intermediate edge"* |

Three failure signatures worth recognizing before you open the troubleshooting page:

1. **`torch.export` fails on your model** → graph mode is unavailable at all. Fall back to `EAGER`
   for weight-only work. ✅ The repo documents `EAGER` as *"the fallback when a model is not
   exportable"*.
2. **A config key is rejected.** ✅ Verified: graph-mode configs **reject non-`"*"` string keys** and
   output keys outside `{"*", 0}`.
3. **A feature is graph-only and you are in eager.** ✅ Verified for KV-cache quantization:
   `kv_cache_quant_configs` raises
   `ValueError: kv_cache_quant_configs is only supported with ExecutionMode.GRAPH (got ...)`.

### 12.4 `utils/activation_comparison.md` — SNR per tensor, before you ever convert

This is the closest thing `coreai-opt` has to the Debugger's sync points, and it runs entirely in
PyTorch on the *prepared* (fake-quantized) model. It reports a **signal-to-noise ratio in dB** for
each tensor, pairing the original tensor with its post-fake-quantize counterpart.

> ✅ **VERIFIED** — `apple/coreai-optimization`, `docs/src/utils/activation_comparison.md:286-295`,
> a complete worked output for a toy `Conv2d → ReLU → Linear` model at default INT8, graph mode,
> verbatim:
>
> ```text
> conv_weight   -> activation_post_process_1  SNR = 47.17 dB
> conv_bias     -> conv_bias                  SNR = inf dB
> linear_weight -> activation_post_process_4  SNR = 48.13 dB
> x             -> activation_post_process_0  SNR = 43.20 dB
> conv2d        -> conv2d                     SNR = 42.40 dB
> relu          -> activation_post_process_2  SNR = 38.94 dB
> flatten       -> activation_post_process_3  SNR = 38.94 dB
> linear        -> activation_post_process_5  SNR = 35.74 dB
> ```

Read that table the way you read a sync-point list, and three things jump out that generalize:

- **`inf dB` means "untouched".** `conv_bias -> conv_bias` maps to itself: bias is not quantized by
  the weight-only spec (`op_state_spec={"weight": …}` targets weights and **excludes** `bias` — ✅
  verified). An `inf` row is a fast check that your spec scoped the way you intended.
- **SNR degrades monotonically downstream.** 43.20 at the input, 42.40 after conv, 38.94 after ReLU,
  35.74 after linear. Error accumulates. This is why a per-layer bar is more useful than a
  whole-model number, and why the *shape* of the degradation matters more than any single row.
- **`relu` and `flatten` are identical at 38.94.** Flatten is a pure reshape; it neither adds nor
  removes error. A reshape row that *differs* from its producer is a red flag — it means a layout
  conversion did something numerically.

> 🔴 **GAP — the public function name and signature for this utility.** The page name
> (`utils/activation_comparison.md`), its position in `coreai-opt`'s docs, and a complete worked
> output are all captured; the API entry point that produces the table was not read in this corpus,
> and it does not appear in the `__all__` inventory captured for `coreai_opt.inspection` or the
> quantization packages. **Resolution:** `make api-list MODULE=coreai_opt.<pkg>` in a checkout (the
> repo ships that target and enforces `__all__` discipline in `tests/test_api_visibility.py`), or
> read the page. **Safe default meanwhile:** you can reproduce the essential measurement yourself in
> about ten lines — the prepared model from `quantizer.prepare(...)` is a normal `nn.Module`, so
> register forward hooks on the modules you care about, run one batch through both the original and
> the prepared model, and compute `10 * log10(sum(x**2) / sum((x - x_q)**2))` per tensor. That is what
> SNR in dB is, and it gives you the same ordering information without an unverified API name.

### 12.5 When to use which layer

| Question | Tool | Cost |
|---|---|---|
| Will my config match the modules I think it will? | `ModelInspector` | seconds, no export |
| Which layers does compression hurt most, in PyTorch? | activation comparison / SNR (§12.4) | one batch |
| Does the *converted* model match PyTorch? | Debugger sync points (§10) | a conversion + a reference run |
| Does the converted model match PyTorch **on the device**? | Debugger sync points with a device Target | + a paired device |
| Does the decoding loop still produce the same tokens? | your own gate (§10.6) | your code |

Work down that table, not up. Every row is more expensive than the one above it, and the cheap rows
catch most of the bugs.

---

## 13. `coreai_torch.debugging` — the same jobs, in Python

Neither WWDC session mentions this module, and it is the most underrated thing in the Core AI Python
stack. It does programmatically most of what the Debugger does in a window — which means it can run
in CI, on a build machine, with no GUI and no paired device.

> ✅ **VERIFIED** — module layout, from `ls -R coreai_torch/debugging`:
> `benchmarker.py`, `comparator.py`, `debug_info.py`, `graph_diff.py`, `graph.py`, `inspector.py`,
> `search_strategy.py`, `torch_utils.py`, `validator.py`.
> **Nearly everything in this module is `async`.**

Same environment prerequisites as §7.3: `USE_LOCAL_COREAI=1`, `ENABLE_DEBUG_INFO=1`.

### 13.1 Validator — bisecting to the first NaN or Inf

> ✅ **VERIFIED** — `apple/coreai-torch`, `coreai_torch/debugging/validator.py`, signatures:
>
> ```python
> def create_validator_for_exported_program(
>     program: torch.export.ExportedProgram,
>     strategy: SearchStrategy[torch.fx.Node, torch.fx.Graph] | None = None,
>     use_caching: bool = True,
> ) -> Validator[torch.fx.Node, torch.fx.Graph]
>
> async def create_validator_for_coreai_program(
>     program: AIProgram,
>     entry_point: str,
>     strategy: SearchStrategy[Operation, Module] | None = None,
>     use_caching: bool = True,
>     specialization_options: SpecializationOptions | None = None,
> ) -> Validator[Operation, Module]
> ```
>
> `Validator` methods: `await validator.check_for_nans(inputs)`, `check_for_infs(inputs)`,
> `check(predicate, inputs)`. Returns `Validator.Result(failed_nodes: list, unknown_nodes: list)`,
> **sorted topologically**. Default strategy is `LevelOrderStrategy.bisection(graph, batch_size=10)`;
> `show_progress=True` by default.

Note the **two constructors** — one for the PyTorch side, one for the Core AI side. That pairing is
the whole point: run both, and you learn whether the NaN was born in PyTorch or in the conversion.

```python
# Docs-verbatim usage, both sides.
from coreai_torch.debugging.validator import (
    create_validator_for_exported_program,
    create_validator_for_coreai_program,
)

# PyTorch side
validator = create_validator_for_exported_program(exported)
result = await validator.check_for_nans(inputs=example_input)
if result.failed_nodes:
    print(f"NaN detected at: {result.failed_nodes[0]}")     # topologically first

# Core AI side
validator = await create_validator_for_coreai_program(coreai_program, "main")
result = await validator.check_for_nans(inputs={"x": torch.randn(2, 4)})
```

`failed_nodes` being topologically sorted is the useful property: `failed_nodes[0]` is the **first**
operation that went bad, not an arbitrary one. Everything downstream of it is a consequence.

Arbitrary predicates work too, which turns this into a general bisector:

> ✅ **VERIFIED** — `docs/api/debugging.md`, verbatim:
> ```python
> def check_large_values(outputs):
>     return any(abs(arr).max() > 1000.0 if arr is not None else False for arr in outputs)
>
> result = await validator.check(check_large_values, inputs=example_input)
> ```

That predicate form is how you hunt fp16 saturation: set the threshold at 65504 and find the first
op whose output cannot survive a half-precision cast.

### 13.2 Search strategies

> ✅ **VERIFIED** — `coreai_torch/debugging/search_strategy.py`. `LevelOrderStrategy` static
> factories, all `(graph, batch_size=10, initial_scope_id=None)`:
> `top_down()` · `bottom_up()` · `bisection()` (the default; fastest to the first issue) ·
> `auto()` — *"selects the sparsest level (fewest nodes) at each step"*.

```python
from coreai_torch.debugging.search_strategy import LevelOrderStrategy

strategy = LevelOrderStrategy.bisection(graph, batch_size=10)  # default
strategy = LevelOrderStrategy.top_down(graph)                  # systematic, inputs → outputs
strategy = LevelOrderStrategy.auto(graph)                      # adaptive
```

Use `top_down` when you want the complete picture (a CI report) and `bisection` when you want the
answer (an afternoon).

### 13.3 Comparator — PyTorch vs Core AI, with tolerances

> ✅ **VERIFIED** — `coreai_torch/debugging/comparator.py`:
>
> ```python
> async def create_comparator_for_programs(
>     source_program: torch.export.ExportedProgram,
>     target_program: AIProgram,
>     target_entry_point: str,
>     strategy=None,
>     use_caching: bool = True,
>     exclude_ops: frozenset[str] = _DEFAULT_EXCLUDED_OPS,   # view/reshape ops; pass frozenset() to disable
>     specialization_options: SpecializationOptions | None = None,
> ) -> Comparator[...]
> ```
>
> Usage, verbatim from `docs/api/debugging.md`:
> ```python
> comparator = await create_comparator_for_programs(
>     source_program=exported_program, target_program=coreai_program, target_entry_point="main"
> )
> result = await comparator.compare_with_tolerance(
>     inputs={"x": example_input}, rtol=1e-5, atol=1e-8
> )
> if result.failed_nodes:
>     for source_op, target_op in result.failed_nodes:
>         print(f"Mismatch: {source_op} vs {target_op}")
> ```
> *"The ID map between torch and coreai ops is auto-extracted from the AIProgram's debug info."*

That last sentence is §7 again: **this API only works on a DEBUG-converted program.** Strip the debug
info and the comparator loses its ability to pair operations, exactly as the Debugger loses its
Source Viewer.

This is the closest programmatic analogue to a sync-point session, with two differences worth
knowing: it uses `rtol`/`atol` rather than a similarity metric, and it excludes view/reshape ops by
default — those are the ops most likely to be restructured by conversion and least likely to be
numerically meaningful.

### 13.4 Inspector and benchmarker

> ✅ **VERIFIED** — `coreai_torch/debugging/inspector.py`:
> ```python
> from coreai_torch.debugging.inspector import CoreAIInspector
> from coreai.runtime import AIModel
>
> ai_model = await AIModel.load(Path("my_model.aimodel"))
> inspector = CoreAIInspector(model=ai_model, function_name="main")
> results = await inspector.get_intermediates_for_ops(
>     [1, 5, 10, 15], inputs={"x": np.random.randn(2, 4).astype(np.float32)}
> )
> ```
> Class hierarchy: `Inspector` (ABC) → `CachingInspector`, `TorchFXInspector(exported_program=…)`,
> `CoreAIInspector(model, function_name="main", temp_dir=None)`.

> ✅ **VERIFIED** — `coreai_torch/debugging/benchmarker.py`:
> ```python
> async def benchmark_coreai_program(
>     coreai_program: AIProgram,
>     inputs: dict[str, Any],
>     entry_point: str = "main",
>     num_runs: int = 1,
>     excluded_operations: tuple[str, ...] | None = None,   # default ("coreai.graph", "coreai.constant")
>     specialization_options: SpecializationOptions | None = None,
> ) -> BenchmarkResult
> ```
> `BenchmarkResult.write_summary(sys.stdout)` and `.get_module_timings()` →
> `{name: ModuleTiming}` with `.aggregated_op_stats.average` in milliseconds.

```python
from coreai_torch.debugging.benchmarker import benchmark_coreai_program
import sys

result = await benchmark_coreai_program(
    coreai_program=coreai_program, inputs={"x": torch.randn(2, 4)}, num_runs=50
)
result.write_summary(sys.stdout)
for name, module in result.get_module_timings().items():
    print(f"{name}: {module.aggregated_op_stats.average:.3f}ms avg")
```

**Per-module timings on a Mac, without Instruments and without an app.** This is the fastest way to
answer "which block is the hot one" during authoring — and note that it reports by *module*, the same
grouping the Debugger's Navigator uses, for the same reason (§7).

> ⚠️ **Caveat, verified and worth heeding:** the only benchmarker test in `apple/coreai-torch` is
> marked `@pytest.mark.skip(reason="debugger issue (will be solved later)")`. This API is real and
> exported, but its automated coverage is currently disabled upstream. Treat its numbers as
> directional — for *ranking* modules, not for publishing latency figures. Publish numbers from a
> device, from a Release build, via the Instruments template.

### 13.5 Graph diff — did `optimize()` change what I think it changed?

> ✅ **VERIFIED** — `coreai_torch/debugging/graph_diff.py`:
> ```python
> def compute_exported_program_diff(source_program, target_program) -> GraphDiff
> def compute_coreai_program_diff(source_program, target_program, *, entry_point: str | None = "main") -> GraphDiff
> def compute_per_graph_diff(...)          # composite-aware
> def write_diff(diff, source_graph, target_graph, *, output=None, indent_size=2, max_items=None) -> None
> ```
> `GraphDiff` fields include `is_isomorphic`, `source_to_target_mapping`, `unmapped_source_nodes`,
> `unmapped_target_nodes`, and a `summary: GraphDiffSummary` carrying node/edge counts and
> `unmapped_{source,target}_{node,edge}_count`. Matching uses `_greedy_topological_match`,
> documented as *"much faster than `subgraph_isomorphisms_iter` for large graphs, providing O(n)
> matching instead of exponential worst case"*.

```python
from coreai_torch.debugging.graph_diff import compute_coreai_program_diff, write_diff
import sys

diff = compute_coreai_program_diff(program_before, program_after, entry_point="main")
if diff.is_isomorphic:
    print("structurally identical")
else:
    print(f"{diff.summary.unmapped_source_node_count} nodes disappeared")
    write_diff(diff, diff.source_graph, diff.target_graph, output=sys.stdout, max_items=20)
```

This is the tool for the `optimize()` silent-deletion class of bug from §8.2, and for "which of my
two exports is different, and how".

### 13.6 Two CLI tools nobody mentions

> ✅ **VERIFIED** — `apple/coreai-torch`, `tools/`. Both are run as plain scripts
> (`python tools/<name>/<name>.py`); they are **not** console-script entry points — there is no
> `[project.scripts]` in `pyproject.toml`, so `graphdiff` on your `PATH` is not a thing.
>
> ```
> usage: graphdiff [-h] [--entry-point NAME] [--max-items N] [--output FILE] SOURCE TARGET
>
> positional arguments:
>   SOURCE              source AIModel asset (.aimodel)
>   TARGET              target AIModel asset to compare against (.aimodel)
> options:
>   --entry-point NAME  coreai.graph entry point to compare (default: all graphs)
>   --max-items N       limit the number of items shown in the diff table
>   --output FILE       write output to FILE (.html for styled HTML, otherwise plain text)
> ```
> **Exit codes: `0` isomorphic, `1` structural differences, `2` input error** — which makes it
> directly usable as a CI gate. Composite-aware by default: it diffs `main` vs `main` and matches
> composite sub-graphs via paired `coreai.invoke` callees (e.g. `@sdpa_abc123` ↔ `@sdpa_def456`).
> Dependencies: `coreai` (for `AIModelAsset`) and `networkx`.
>
> ```
> usage: freqop [-h] [--plot] FILE [FILE]
> positional arguments:
>   FILE        AIModel asset to analyze (.aimodel)
> ```

`graphdiff`'s exit codes are the single most useful CI hook in this section:

```bash
# Fail the build if today's export is not structurally identical to the golden asset.
python tools/graphdiff/graphdiff.py golden/MyModel.aimodel build/MyModel.aimodel \
    --output artifacts/graphdiff.html
case $? in
  0) echo "graph unchanged" ;;
  1) echo "STRUCTURAL DIFF — see artifacts/graphdiff.html" ; exit 1 ;;
  2) echo "graphdiff input error" ; exit 2 ;;
esac
```

That catches the case where a converter upgrade, a PyTorch bump, or a config change quietly
restructures your graph — which, as §15 shows, is not hypothetical.

### 13.7 The one-screen mapping

| GUI feature | Python equivalent | Runs in CI? |
|---|---|---|
| Structure viewer | `graph_diff` / `tools/graphdiff` | ✅ (exit codes) |
| Inspector output tensors (after a run) | `CoreAIInspector.get_intermediates_for_ops` | ✅ |
| Sync points vs a reference run | `create_comparator_for_programs` + `compare_with_tolerance` | ✅ |
| "which op first goes bad" | `Validator.check_for_nans` / `.check(predicate)` | ✅ |
| Reference-run capture | `save_intermediates` | ✅ |
| Per-module timing | `benchmark_coreai_program` | ⚠️ directional only |
| Source viewer (Python line) | *no equivalent* | ❌ |
| Difference heatmaps | *no equivalent* | ❌ |
| Run on a paired **iOS** device | *no equivalent* | ❌ |

The last three are why the Debugger is worth downloading. Everything above them belongs in your
pipeline, not in a window.

---

## 14. A playbook: which tool, in which order

Two flows, depending on which of the two things is wrong.

### 14.1 "It is slow"

```
1. Open the Core AI gauge report page FIRST (§2.5), then run the app.
2. Read the three medians. Is there a Specialization event at all?
      YES on every launch → cache miss. Check SpecializationOptions stability
                             and whether an OS update just landed. (§2.8, §5.4)
      YES on first launch only → normal; is it in an interactive flow? (§5)
      NO  → fine, move on.
3. Are Load events repeating? → you are reloading the model. Hold the AIModel.
4. Is median inference within ~2× of expectation?
      NO → Profile in Instruments (§3). Check the Neural Engine and GPU lanes:
           are they busy during your Inference events, or is this on the CPU?
      YES but the app still feels slow → take a trace anyway and look at the SHAPE
           of the Inference lane over time (§4). Slopes do not show up in medians.
5. Inference intervals widening monotonically?
      → no KV cache, or states not wired. §4.3–§4.4.
6. Setup growing relative to Inference?
      → per-inference preparation dominating. Suspect reshapes;
        check SpecializationOptions.expectFrequentReshapes for dynamic-shape models.
```

### 14.2 "It is wrong"

```
1. Is it wrong in PyTorch too?
      → Validator on the ExportedProgram (§13.1). If yes, stop; this is not a Core AI bug.
2. Did compression skip layers you believe it compressed?
      → check the size arithmetic, and grep the compression logs for
        "Skipping palettization" (§11.4). Silent skips are common.
3. Does your compression config match the modules you think it does?
      → ModelInspector.get_matched_ops_for_module_name (§12.1). Two minutes.
4. Where does the error enter, in PyTorch terms?
      → activation SNR per tensor (§12.4) on the prepared model. No conversion needed.
5. Where does the error enter, in the CONVERTED model?
      → save_intermediates from the uncompressed model (§9)
        → Core AI Debugger comparison session, Configuration B = Intermediates File (§10.2)
        → sort by Similarity, walk the worst pairs, look for a MODULE pattern (§10.3)
6. Got a module pattern?
      → cross it with the parameter budget. Cheap module → exclude it with None (§11.6).
        Expensive module → different bit-width, not an exemption.
7. Wrong only on the device, right on the Mac?
      → comparison session across two CONFIGURATIONS of the same asset (§10.2).
        No Python needed.
8. Autoregressive model?
      → sync points are necessary, not sufficient. Add a greedy token-exact
        decode gate (§10.6). Always.
9. Won't load at all, with an MLIR/AICode error?
      → not a numerics problem. §15.
```

### 14.3 The five habits that prevent most of this

1. **Open the gauge report page before you reproduce anything.** The hand-off options are not
   retroactive (§2.5).
2. **Convert twice: a DEBUG asset for debugging, a RELEASE asset for shipping** (§7.4). They are the
   same graph.
3. **Export `USE_LOCAL_COREAI=1` and `ENABLE_DEBUG_INFO=1` in the shell you convert from** (§7.3).
4. **Keep a golden `.aimodel` and gate on `graphdiff`'s exit code** (§13.6). Converter and PyTorch
   upgrades restructure graphs.
5. **Know your parameter distribution by module before you compress** (§11.8). The whole SAM3
   diagnosis turned on a number — 4% — that was known before the debugger was opened.

---

## 15. ⚠️ Provenance: the coreai-torch 0.4.0 IR-location incident

This guide has spent fourteen sections arguing that debug metadata is what makes a model debuggable. Here
is the other edge of that: **debug metadata is content in your asset, it has a format, and formats
have versions.**

### 15.1 What happened

> ⚠️ **Community-reported** — `notes/repos/john-rocky-models.md`
> (`conversion/coreai-torch-041-ir-incident.md`, 2026-07-18), corroborated by
> `apple/coreai-torch` issue **#37** and by `apple/coreai-models` issue #77. Attribute as
> community-reported with an Apple-maintainer resolution; the error strings and the maintainer's
> answer are quoted verbatim from those threads.

> *"Every `.aimodel` converted with `coreai-torch` **0.4.0** stops loading on **iOS/macOS 27 beta 2
> and later**. It runs on beta 1."*

On beta 2 and later, **both** `AIModel.load` **and** `coreai-build compile` abort with:

```
error: expected AICode versioned location, got: loc(fused<...>)
error: Failed to convert to versioned IR
LLVM ERROR: cannot unwrap empty `odiec_module_t`
```

The full form of the first line shows exactly what the compiler choked on — the module call stack
from §7.1, serialized as an MLIR `fused` location:

```
loc(fused<{call_stack = ["PixelShuffle$1", "Upsampler$1", "Sequential$19", "EDSR$1"],
  identifiers = ["pixel_shuffle"]}>[...]): error: expected AICode versioned location, got: loc(fused<...>)
```

Root cause, from Apple's own issue thread and the 0.4.1 release notes:

> *"0.4.0 baked PyTorch stack traces into the IR as MLIR `fused` locations; the beta-2 compiler no
> longer parses that nested form. **It fires on deep module hierarchies.**"*

So: the feature that gives you the Source Viewer, written in a form a later compiler rejected. Deep
module hierarchies are exactly the models that benefit most from module grouping — which means **the
assets most worth debugging were the ones most likely to break.**

### 15.2 ⚠️ The silent failure inside the loud failure

> ⚠️ **SILENT FAILURE — `coreai-build inspect` reads a broken asset perfectly, which makes the
> problem look recoverable when it is not.** This is the cruel part of the incident and the reason it
> is worth 60 lines in a debugging guide.
>
> Verified negative results, all community-reported and all worth knowing because each one is a day
> someone lost:
>
> | What people tried | What actually happened |
> |---|---|
> | `coreai-build package` | *"re-emits the asset (producer bumps) but leaves IR locations untouched; compile fails identically."* |
> | Pinning `coreai-core` back to `1.0.0b1` | *"the gate is **OS-side**, not in the wheel."* Wheel-pinning cannot help. |
> | Re-running AOT with the beta-3 toolchain | *"dies at the same op."* |
> | `coreai-build inspect` | **succeeds** — *"function signatures, inputs/outputs and states all print correctly. So the payload itself isn't corrupt; only the location metadata is in the pre-0.4.1 form."* |
>
> The reporter's own summary: *"which makes it look recoverable. **It isn't.**"* An `inspect` that
> prints a clean function table is *not* evidence that a model will load. The two code paths read
> different parts of the file.

### 15.3 Auditing a tree — the producer fingerprint

You do not need dates, git history, or guesswork. A 0.4.1-converted asset writes a `producer` field
into its `metadata.json`; a 0.4.0 one does not.

> ⚠️ **Community-reported**, verbatim:
>
> ```
> 0.4.1 (good):  {"producer": "coreai-core 1.0.0b2", "assetVersion": "2.0", "creationDate": ...}
> 0.4.0 (dead):  {"assetVersion": "2.0"}
> ```
>
> *"Audit any tree by that field alone — no dates, no guessing."*
>
> ⚠️ **One caveat that will bite you if you skip it:** *"`.aimodelc` bundles **always** carry a
> `producer` (the `coreai-build-<ver>` string), so for those use the **source** `.aimodel`'s
> producer, not the compiled one."* A compiled asset's producer tells you which compiler ran, not
> which converter produced the IR it compiled.

```python
#!/usr/bin/env python3
"""Audit a tree of .aimodel bundles for the missing-producer fingerprint.

An .aimodel is a DIRECTORY bundle containing metadata.json alongside the IR.
Assets with no "producer" field were converted by coreai-torch 0.4.0 and will
not load on iOS/macOS 27 beta 2 or later. Check .aimodel sources, not .aimodelc.
"""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
suspect, ok, unreadable = [], [], []

for meta in sorted(root.rglob("*.aimodel/metadata.json")):
    try:
        data = json.loads(meta.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        unreadable.append((meta.parent, exc))
        continue
    (ok if "producer" in data else suspect).append(
        (meta.parent, data.get("producer"), data.get("assetVersion"))
    )

for path, producer, version in ok:
    print(f"OK       {path}  producer={producer!r} assetVersion={version!r}")
for path, _, version in suspect:
    print(f"SUSPECT  {path}  NO producer field  assetVersion={version!r}")
for path, exc in unreadable:
    print(f"UNREAD   {path}  {exc}")

print(f"\n{len(ok)} ok, {len(suspect)} suspect, {len(unreadable)} unreadable")
sys.exit(1 if suspect else 0)
```

> ✅ **VERIFIED** — the `.aimodel` is a **directory bundle**, not a file: Apple's `AIModelAsset`
> documentation calls it *"an `.aimodel` bundle on disk"*, and `save_asset()` returns an
> `AIModelAsset` for a directory. Community reading of the bundle contents gives
> `{metadata.json, main.mlirb, main.hash}` — the IR plus a manifest; the exact non-`metadata.json`
> filenames are ⚠️ community-reported, and the script above depends only on `metadata.json`, which
> Apple names.

### 15.4 The fix, from the maintainer

Re-converting works but is expensive at zoo scale. There is a cheaper path, and it came from the
`coreai-torch` maintainer directly:

> ⚠️ **Community thread, Apple-maintainer answer** — `apple/coreai-torch` issue #44, @cymbalrush,
> verbatim: *"Thank you for reporting the issue. Could you try using `strip_debug_info` to remove
> debugging metadata? This should prevent the compiler failure. After stripping the debug
> information, make sure to save the updated asset."*

```python
# Recover a 0.4.0-converted asset WITHOUT re-converting.
# Requires coreai-torch >= 0.4.1 installed (the fix ships in the newer wheel).
from pathlib import Path

from coreai.authoring import AIModelAsset
from coreai_torch.debugging.debug_info import strip_debug_info

asset = AIModelAsset.load(Path("model.aimodel"))
program = asset.program

strip_debug_info(program)                                # in-place
program.save_asset(Path("model_stripped.aimodel"))
```

> ✅ **VERIFIED** — `coreai_torch.debugging.debug_info.strip_debug_info(program: AIProgram) -> None`
> is **in-place**: it *"replaces every op location with an unknown-file location plus a fresh
> sequential `coreai` op ID"*, and is documented as *"useful for reducing asset size when full debug
> traces are no longer needed."* `TorchConverter`'s own docstring points at it: *"Call
> `coreai_torch.debugging.debug_info.strip_debug_info` to remove debug metadata from an
> already-converted program."*
>
> ⚠️ The maintainer's snippet in the thread reads `coreai_program = strip_debug_info(coreai_program)`
> — assigning the return value of a function documented as returning `None`. Written as a statement
> above, which matches the documented in-place semantics. If a future release changes it to return a
> program, the statement form still works.

**And the cost of that fix, stated plainly:** you have just deleted the source mapping. The recovered
asset loads, runs, and is correct — and its Source Viewer is gone (§7.2), its comparator can no
longer pair ops with PyTorch nodes (§13.3), and its Navigator can no longer group by module (§6.5).
Strip to ship, never to debug.

### 15.5 The environment that avoids the whole problem

> ⚠️ **Community-reported** — the working pin set as of 2026-07-18: `coreai-torch` **0.4.1+**,
> `coreai-core` **1.0.0b2**, `coreai-opt` **0.2.1**, on a pinned **`torch==2.9.0`** — with the
> warning *"do NOT let `uv` bump torch to 2.11 — it breaks torchvision with a circular import and
> every export dies at load."* Xcode 27 **Beta 3** (`27A5218g`) for AOT (`xcrun coreai-build` →
> `3600.75.3`).
>
> A separate, easily-confused issue in the same era: **beta-2-or-earlier `.aimodelc` files also need
> a beta-3 recompile** (Apple radar 181264112). *"That is a **separate** issue from the 0.4.0
> conversion break — do not conflate them."*

> ⚠️ **SILENT FAILURE — a stale `egg-info` shadowing the installed wheel.** Community-reported,
> verbatim: *"**Never run python with the coreai-torch clone as cwd**: its `coreai_torch.egg-info`
> (0.4.0) shadows the installed 0.4.1 via `sys.path[0]`, so **exports silently use 0.4.0**."*
> You upgrade the wheel, you verify the version in a fresh shell, you convert from the clone
> directory out of habit, and you produce broken assets that report a correct toolchain version.
> The producer-field audit in §15.3 is what catches this, and it is the only thing that does.

### 15.6 What to generalize from this

1. **Debug metadata is an artifact with a format, and formats have compatibility windows.** It is not
   inert commentary attached to your model. It is parsed by a compiler that ships with the OS.
2. **An asset that inspects cleanly is not an asset that loads.** Different code paths read different
   parts of the bundle. Your CI gate must be a **load**, ideally a load-and-run, not an inspect.
3. **Provenance belongs in your build outputs.** The `producer` field exists precisely so that a tree
   of assets is auditable without archaeology. Record which converter version, which torch version
   and which OS produced every asset you ship — the field is free and it is the difference between a
   ten-minute audit and a week.
4. **Wheel-pinning is not a rollback strategy when the gate is OS-side.** Three of the four attempted
   recoveries in §15.2 failed for that one reason.
5. **Cross-link:** this is a migration hazard as much as a debugging one. Part 17 covers moving a
   26-era or early-beta-27 project forward; the producer audit and `strip_debug_info` recipe belong
   in that checklist too.

---

## 16. Quick reference

**Version floor**

| Thing | Floor |
|---|---|
| Core AI framework | 27.0 on all seven platforms, all Beta |
| Debug gauge, Core AI Instruments template | Xcode 27 |
| Core AI Debugger host | **macOS 27+** |
| Core AI Debugger paired devices | iOS 27+, iPadOS 27+, macOS 27+ (no visionOS/tvOS/watchOS) |
| `save_intermediates`, `strip_debug_info`, `coreai_torch.debugging` | `coreai-torch` 0.4.1+, `coreai-core` 1.0.0b2 |
| `ModelInspector` | `coreai-opt` 0.2.1 |
| AOT (`coreai-build`) target devices | A17 Pro+, M1+ Mac, M2+ Vision Pro only |

**Event categories**

| Category | Gauge | Instruments | Meaning |
|---|---|---|---|
| Specialization | orange | **green** | one per model at most; none if AOT-specialized or cached |
| Load | green | **cyan** | once at start of runtime; repeats = you are reloading |
| Setup | *(absent)* | magenta | precedes **each** inference |
| Inference | blue | blue | one complete inference |

**Debugger metrics** — PSNR (default) · MAE · MSE · Max Absolute Error · Mean Relative Error.
Colour indicators are metric-aware: green is always good.

**PSNR bars** (✅ Apple's own `model-authoring` agent skill)

| Comparison | Bar |
|---|---|
| re-authored vs source | > 70 dB |
| ANE-layout vs GPU-layout | > 70 dB |
| compiled vs torch | ≥ 40 dB |
| 8-bit palettization | > 55 dB (flag < 50) |
| 4-bit palettization | ~40 dB (flag < 35) |
| 2-bit palettization | 25–35 dB — *"usually unacceptable"* |

**The Python surface, one line each**

```python
from coreai_torch import TorchConverter, get_decomp_table
TorchConverter(mode=TorchConverter.Mode.RELEASE)          # ship; DEBUG is the default
converter.add_exported_program(ep, input_names=…, output_names=…, state_names=…, entrypoint_name="main")
program.optimize()                                        # in-place, return value unused
program.save_asset(Path("m.aimodel"))                     # -> AIModelAsset; optional 2nd metadata arg

from coreai_torch.debugging.torch_utils import save_intermediates, load_intermediates
save_intermediates(program=ep, inputs=…, output_dir=…, coreai_program=…, enable_autocast=False, model_name="main")
load_intermediates(Path("out/main.aimodelintermediates"))  # -> DebugTrace(.inputs/.outputs/.intermediates)

from coreai_torch.debugging.validator import create_validator_for_exported_program, create_validator_for_coreai_program
await validator.check_for_nans(inputs=…) / .check_for_infs(…) / .check(predicate, …)

from coreai_torch.debugging.comparator import create_comparator_for_programs
await comparator.compare_with_tolerance(inputs=…, rtol=1e-5, atol=1e-8)

from coreai_torch.debugging.benchmarker import benchmark_coreai_program
from coreai_torch.debugging.graph_diff import compute_coreai_program_diff, write_diff
from coreai_torch.debugging.debug_info import strip_debug_info          # in-place; strips source mapping

from coreai_opt.inspection import ModelInspector
inspector.get_matched_ops_for_module_name(r"detector.*")  # prove your pattern matches
```

**Environment**

```bash
export USE_LOCAL_COREAI=1     # preserve op-level debug metadata; also skips the host symbol-version check
export ENABLE_DEBUG_INFO=1    # preserve op-level debug metadata
# optional, off by default "for performance reasons":
export VERIFY_DEBUGINFO_LOCATIONS=1
```

**The seven rules that prevent the seven silent failures in this guide**

1. Link `CoreAI.framework` **directly** from the app target, or there is no gauge at all. (§2.1)
2. Open the gauge's report page **before** reproducing; the More menu is not retroactive. (§2.5)
3. Read the **category name**, never the colour, when moving between gauge and Instruments. (§3.4)
4. Convert a DEBUG asset alongside the RELEASE one, or the Source Viewer is silently absent. (§7.2)
5. Prove your compression exclusion pattern matches ops before trusting it — and use the same
   execution mode you will compress with. (§12.1)
6. Check compressed size against the bit-width arithmetic; silent layer skips are log-only. (§11.4)
7. For autoregressive models, add a greedy token-exact decode gate; sync points cannot see drift
   that only appears at step 12. (§10.6)

**Declared gaps, in one place** (nothing is guessed inside any of them)

- On-screen lane/metric names and the detail-pane columns in Xcode 27's Instruments — §3.5
- Whether the Instruments template works against the Simulator; whether a cache-hit metric exists — §3.5
- Why the gauge omits `Setup`, and whether that inflates its Inference median — §3.4
- Whether the gauge needs a scheme option, and what it costs — §2.8
- The exact shipped strings in the gauge's More menu (`DebugML` leak) — §2.7
- ~~Full `coreai-build compile` flag list; `deviceArchitectureName` value set~~ **closed 2026-07-31**
  (Metal Toolchain component; `notes/sdk-interfaces/coreai-build-help-27.0-beta.txt`) — the
  code→device mapping remains community-only — §5.2
- Full value lists for Target / Compute Units / Graph Visualization in the Debugger scheme dialog — §8.2
- Whether the Debugger can attach to visionOS / tvOS / watchOS — §6.1
- Which PyTorch model Apple intends in `save_intermediates(program=…)` — §9.3
- Contents of `debugging/graph_mode_troubleshooting.md` — §12.3
- The public API entry point behind `utils/activation_comparison.md` — §12.4
- `ModelInspector.format_summary` keyword arguments — §12.1
- How long the `USE_LOCAL_COREAI` / `ENABLE_DEBUG_INFO` preview requirement lasts — §7.3

---

## 17. Sources and evidence ledger

**Strongest class available for this topic — shipped repository source and Apple's own agent
skills.** There is no Apple sample-code project for Core AI (0 `sampleCode` entries across 312
indexed symbols; `/documentation/updates/coreai` 404s), so nothing in this guide was checked against
a compiling first-party app.

- `apple/coreai-torch`:
  - `coreai_torch/converter.py` — `TorchConverter.Mode`, the keyword-only `mode=Mode.DEBUG` default,
    the `strip_debug_info` pointer in the docstring.
  - `coreai_torch/debugging/torch_utils.py:905-913` — the `save_intermediates` signature and
    docstring, verbatim.
  - `coreai_torch/debugging/{validator,comparator,inspector,benchmarker,graph_diff,debug_info,search_strategy}.py`
    — signatures in §13.
  - `docs/api/debugging.md` — usage examples, the two preview environment variables,
    `VERIFY_DEBUGINFO_LOCATIONS`.
  - `docs/api/TorchConverter.md` — `add_exported_program`, the state/IO-naming contract, the
    breaking-change notes.
  - `tests/test_stateful.py:58-95` — the `register_buffer` → state mechanism and the resulting IR.
  - `tests/test_get_module_hierarchy.py` — the `ClassName$N` module-hierarchy naming.
  - `tools/graphdiff/graphdiff.py`, `tools/freqop/freqop.py` — usage strings and exit codes.
- `apple/coreai-optimization`:
  - `src/coreai_opt/quantization/config/_presets/quantizer_config.py` — the `w4` preset verbatim.
  - `src/coreai_opt/quantization/config/quantization_config.py:576-582` — config precedence and the
    `None`-disables rule.
  - `src/coreai_opt/quantization/quantizer.py` — the GRAPH/EAGER comparison table and the
    not-equivalent warning.
  - `src/coreai_opt/inspection/` — `ModelInspector` signature, methods, exported types.
  - `docs/src/debugging/model_inspection.md:61-91` — the tree legend.
  - `docs/src/utils/activation_comparison.md:286-295` — the worked SNR table.
  - `Makefile` — `USE_LOCAL_COREAI ?= 1` and its stated reason.
- `apple/coreai-models`:
  - `skills/skills/model-authoring/SKILL.md:94-99, :149-153` — **Apple's own PSNR bars and
    palettization table**, the calibration data in §10.5.
  - `python/src/coreai_models/segmentation/pipeline.py:136-142, :208-286` — the three-entrypoint
    split, the per-function compression recipe, the `enable_per_channel_scale` / ANE rank-5 note.
  - `models/sam3/README.md` — 848M parameters, the shipped asymmetric recipe.
  - `swift/Sources/CoreAILanguageModels/InferenceEngines/CoreAISequentialEngine.swift:275-291` — the
    verified `run(inputs:states:outputViews:)` call site with `MutableViews` and `consume`.
  - `export/compiler.py:69-72` — diffusion quantization failures swallowed with a warning.

**Apple documentation (fetched 2026-07-27).** Two of these pages carry `termList` blocks that the
usual markdown mirror silently drops; both were recovered from Apple's raw DocC JSON, and both are
load-bearing here (the four Instruments components + four event categories; the five similarity
metrics).

- `/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models` (collection)
- `/documentation/coreai/monitoring-model-performance-with-the-debug-gauge`
- `/documentation/coreai/analyzing-model-runtime-performance-with-instruments`
- `/documentation/coreai/inspecting-core-ai-models-with-core-ai-debugger`
- `/documentation/coreai/validating-inference-correctness-against-a-reference-run`
- `/documentation/coreai/compiling-core-ai-models-ahead-of-time`
- `/documentation/coreai/managing-model-specialization-and-caching`
- `https://developer.apple.com/core-ai-debugger/` — download page and system requirements

**WWDC26 transcripts.** Weakest of the Apple-sourced classes, and used here only for narration and
for the two worked traces, which exist nowhere else.

- **324** *Meet Core AI* (Ben) — the growing-interval trace and the states fix (§4); the three-tool
  framing (§1.3); the specialization recommendation (§5.3).
- **325** *Dive into Core AI model authoring and optimization* (Sachin; Nicole for the Debugger) —
  the entire Debugger walkthrough (§6, §8, §10) and the SAM3 diagnosis (§11).
- **326** *Integrate on-device AI models into your app using Core AI* (Carina) — the specialization
  sub-event trace and the deployment consequences (§5).

**Community — always attributed as such, never presented as Apple-official.**

- `notes/repos/john-rocky-models.md` — a single-author community model zoo with **self-declared
  uncontrolled benchmark conditions**. Its numbers are frequently unique in this corpus and are
  labelled at every use. Sources for: the 0.4.0 IR-location incident and its recovery (§15), the
  producer-field audit, the ≥1 GB AOT threshold, the real-inputs-vs-constant-probes finding, the
  measurement methodology in §4.6, the ANE/GPU routing reading, the PSNR-vs-token-exactness gap
  (§10.6), and the iOS-bundle-on-Mac warning.
- `apple/coreai-torch` issues **#37** and **#44**, and `apple/coreai-models` #77 — the incident
  threads. #44 carries the maintainer's `strip_debug_info` answer, which is the one Apple-authored
  statement in §15.

**Where sources disagreed, and how this guide ruled**

| Conflict | Ruling |
|---|---|
| Brief said the similarity-metric list beyond PSNR was unknown; Apple's DocC JSON publishes all five | **Notes win.** All five documented in §10.4; the gap is closed and recorded as such. |
| Brief said Instruments lane/metric names come from prose only; the docs give four instruments, four categories, a three-level track hierarchy and literal event labels | **Notes win, partially.** Named as VERIFIED-from-documentation in §3.2–§3.5, with the residual gap narrowed to "what the strings look like on screen". |
| Transcript "4-bit palettization to the two encoders" vs shipped recipe (image w4/gs32, **text w6/gs8**) | Shipped code wins; both stated in §11.7. |
| Transcript "with per-channel scales" vs shipped `enable_per_channel_scale=False` | Shipped code wins; the ANE rank-5 reason is quoted. §11.7 |
| Transcript "`EAGER` works great" vs repo "GRAPH is the recommended default" | Both true of different things; reconciled in §11.3 with the repo's own not-equivalent warning. |
| Apple prose "passing both the model you want to validate and the original source model" vs the actual `save_intermediates` signature | Signature wins; the ambiguity is declared as a 🟡 with a safe default. §9.3 |
| Gauge colours vs Instruments colours (Load/Specialization swapped) | **Both are correct**, quoted verbatim from their own articles; treated as a silent-failure hazard rather than an error. §3.4 |
| Apple's PSNR bars vs the community's token-exactness gate for LLMs | Not a conflict — different failure classes. Both taught; §10.6 explains why PSNR alone is insufficient for autoregressive decoding. |

[^sample-routing-policy]: The policy being interpreted is source code in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s framework default is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
