# The adapter sunset: migrating off custom LoRA adapters

**Part 17 · Migration from pre-iOS 27 · Reference 02**

Custom LoRA adapters for the Foundation Models framework are **discontinued as of OS 27**. Not
deprecated with a drop-in replacement. Not soft-landed behind an `@available` attribute you can
read in a header. Withdrawn — with a differently-shaped replacement in a different framework.

Two Apple staff members said so independently, in two different forum threads, three weeks apart,
and the Adapter Training Toolkit's version page stops at **26.0.0**. That is the entirety of the
public evidence. There is no documentation page announcing it, no release note, no WWDC26 session
that says it out loud. This guide leads with what the evidence actually is, because the size of
the decision you are being asked to make is out of proportion to the size of the announcement.

**Version floor.** You have a shipping app built against **iOS/macOS 26.x** with **Xcode 26**, using
`SystemLanguageModel.Adapter` and a `.fmadapter` bundle, and you are moving to **iOS/macOS 27** and
**Xcode 27**. Everything in §3 and §4 is **26.x-only** and is documented here as history for readers
who still ship a 26.x build. Everything in §7 (Core AI) and §8 (MLX + `MLXFoundationModels`) is
**27.0-only** — `CoreAI` is a new framework in the 27 SDK with no 26 back-deployment, and
`MLXFoundationModels` compiles to an empty library on the 26 SDK. Only §6 (prompting plus guided
generation) works on both, and even there the model underneath it was rebuilt across the boundary.
The adapter APIs themselves were **26.0+**; `tokenCount(for:)` and `contextSize` arrived in **26.4**
and matter to §6's token budgeting.

> ⚠️ **SILENT FAILURE — the defining property of this migration.** Nothing about the adapter
> sunset announces itself at build time. `SystemLanguageModel.Adapter` is not spelled with a
> `@available(..., deprecated:)` attribute we have ever seen quoted, no compiler diagnostic is
> attested, and the packaging CLI still exists on disk in Xcode 26 toolchains. Meanwhile
> `LanguageModelSession.GenerationError` **is** documented as "Deprecated in 27.0" by an Apple
> Frameworks Engineer, which means developers get a deprecation warning for their *error handling*
> and nothing at all for the feature that was actually removed. If you are looking for the compiler
> to tell you, it will not. §2 is the checklist that replaces it.

---

## What this covers

- **§1 — The news, and exactly what the evidence is.** Both Apple-staff statements verbatim, with
  thread IDs, dates and badges. Then the harder part: an explicit list of what those statements do
  *not* say, so you can tell the difference between what is settled and what this guide had to
  construct.
- **§2 — What "no longer supported" concretely means**, claim by claim, each carrying its own
  marker. Includes the two questions nobody has answered — whether an already-shipped 26.x adapter
  still resolves on a device that upgrades to 27, and whether the packaging CLI still emits a
  loadable pack — and the safe default for each.
- **§3 — The historical record.** The full 26.x pipeline: `SystemLanguageModel.Adapter`, the
  `.fmadapter` bundle, `xcrun ba-package foundation-models package`, the entitlement, the three
  `Info.plist` keys, the `StoreDownloaderExtension`, and the `"onDemand": null` manifest defect that
  Transporter rejects with **ITMS-91140**. Written down because it is nowhere else in one place, and
  because a 26.x build you still ship still needs it.
- **§4 — The `compatibleAdapterNotFound` failure**, in detail: an adapter that loads perfectly from
  a local file URL and then cannot be found when the same bytes arrive as an Apple-hosted managed
  asset pack through TestFlight. Apple's answer is one missing call. Plus the ~100 MB-per-call APFS
  leak into a SIP-protected directory, which looks exactly like filesystem corruption.
- **§5 — The decision table**, keyed on *why you built an adapter in the first place*: tone and
  style, domain vocabulary, structured-output reliability, or a genuinely different task. These four
  reasons have four different answers and three different costs.
- **§6 — Path 1: re-frame the task as prompting plus guided generation.** Try this first. It costs
  nothing, keeps you on the system model, and covers more ground than people expect — Apple's own
  code-along deletes structural prompt guidance once `@Generable` is applied. With the honest limits.
- **§7 — Path 2: move the specialised model to Core AI**, driven through `CoreAILanguageModel`. You
  keep `LanguageModelSession`. You take on conversion, size, distribution, specialization latency and
  updates. ⚠️ And on GPU-pipelined bundles you **lose `@Generable` entirely**, because constrained
  decoding needs engine logits that path never exposes — verified in Apple's own repository source,
  down to the error string.
- **§8 — Path 3: move it to MLX**, driven through `MLXFoundationModels`. `mlx-lm`'s LoRA/DoRA is the
  surviving on-device adaptation story: you can genuinely still fine-tune. Costs: a hard 27.0 SDK
  floor, app size and memory you now manage, and no Neural Engine.
- **§9 — 🔴 The gap, stated prominently.** Apple *named* the migration path — "Core ML or Core AI…
  Background Assets remains a great way to deliver custom models" — and has documented it end to end
  **nowhere**. This guide constructs it from parts. §9 says which parts, and what Apple would have to
  publish to close it.
- **§10 — What to do if you have an adapter shipping to users today.** The support window, how to
  detect and degrade, and a five-release sequence that never leaves you with a broken build.
- **§11 — What not to do.** The fabricated APIs circulating about this exact topic, including an
  on-device LoRA-training API that does not exist and never shipped.

## What this does *not* cover

- **How to train a LoRA adapter with the Adapter Training Toolkit.** That story ended; §3 documents
  the *delivery* half because a shipping 26.x build still needs it, not the training half.
- **The full Core AI runtime** — `AIModel`, `InferenceFunction`, `NDArray`, specialization, the
  cache. [Part 7](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md). Conversion from PyTorch is
  [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md); compression is
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **The full MLX story** — [Part 12](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/README.md) for Python and fine-tuning,
  [Part 13](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/README.md) for Swift and the Foundation Models bridge.
- **Distribution mechanics** — Background Assets, per-architecture variants, update strategy.
  [Part 15, reference 01](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md),
  which carries its own 🔴 GAP on the 2026 Background Assets API surface.
- **The error taxonomy migration** — `GenerationError` → `LanguageModelError`. That is
  [17.3](03-error-taxonomy-migration.md), and it is a separate problem that happens to land in the
  same release.

## What you need

- **Xcode 27** for anything in §6–§8. For §3 you need whatever Xcode 26 toolchain your 26.x build
  currently uses; the `ba-package` subcommand lives there.
- **A physical device on 27.0 or later.** Simulator inference is host-backed, so a Simulator
  result on a macOS 26 host tells you about macOS 26 — the single largest source of phantom bug
  reports in this area; an Apple Designer says so directly, quoted in
  [Part 1, reference 02](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/references/02-platform-and-version-gating.md).
  One measured nuance (✅ **Probe-verified, 2026-07-31**, `probes/` on the 27.0 sim runtime):
  the sim runtime resolves the base model's availability and assets independently of the host's
  Apple Intelligence toggle — plain and guided inference genuinely run there — but tool-calling
  and attachment assets are absent, and nothing about adapters changes: adapter behaviour still
  needs the physical device.
- **An evaluation set before you start.** You are about to change the thing that made your feature
  work. If you cannot measure the difference you cannot make this migration safely, and §6's
  "just prompt it better" advice is unfalsifiable without one.
  [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) is the whole story; §6.7 here is the minimum.
- **The knowledge that this is a product decision, not only an engineering one.** Two of the three
  paths change what your app downloads, how large it is, and how it behaves offline.

---

## Contents

1. [The news, and exactly what the evidence is](#1-the-news-and-exactly-what-the-evidence-is)
2. [What "no longer supported" concretely means](#2-what-no-longer-supported-concretely-means)
3. [The historical record: the 26.x adapter pipeline](#3-the-historical-record-the-26x-adapter-pipeline)
4. [`compatibleAdapterNotFound`, and the leak underneath it](#4-compatibleadapternotfound-and-the-leak-underneath-it)
5. [First, ask why you had an adapter — the decision table](#5-first-ask-why-you-had-an-adapter--the-decision-table)
6. [Path 1 — prompting plus guided generation](#6-path-1--prompting-plus-guided-generation)
7. [Path 2 — Core AI and `CoreAILanguageModel`](#7-path-2--core-ai-and-coreailanguagemodel)
8. [Path 3 — MLX and `MLXFoundationModels`](#8-path-3--mlx-and-mlxfoundationmodels)
9. [🔴 The gap: Apple named the path and documented it nowhere](#9--the-gap-apple-named-the-path-and-documented-it-nowhere)
10. [If you have an adapter shipping to users today](#10-if-you-have-an-adapter-shipping-to-users-today)
11. [What not to do: the fabricated APIs circulating about this exact topic](#11-what-not-to-do-the-fabricated-apis-circulating-about-this-exact-topic)
12. [Quick reference](#12-quick-reference)
13. [Sources and evidence ledger](#13-sources-and-evidence-ledger)

---

## 1. The news, and exactly what the evidence is

### 1.1 The two statements, verbatim

> ✅ **VERIFIED — statement one.** Apple Developer Forums thread **829108**, *"Adapter Problem -
> `compatibleAdapterNotFound`"* (opened by `alex_und3r`, 2026-06-04, 6 replies). Final reply, badged
> **Frameworks Engineer (Apple)**:
>
> > "@alex_und3r, as we announced at WWDC26, custom adapters are unfortunately no longer supported as
> > of OS 27. Instead, you can use the base machine-learning models that are available on people's
> > devices or provide your own custom models using Core ML or Core AI. Background Assets remains a
> > great way to deliver custom models to your users."

> ✅ **VERIFIED — statement two.** Apple Developer Forums thread **831314**, *"Adapter Training
> Toolkit: updated version for OS 27?"* (opened by `tayarndt`). Reply badged **Apple Designer
> (Apple)**:
>
> > "Sorry, we're no longer supporting adapters as of OS 27. I'll update the page."

Both are recorded in our forum research capture, `notes/forums/forum-pain-points.md:247-263`, taken
from live thread fetches on 2026-07-27. They are the first item in that file's own top-ten list of
highest-value facts, which is a fair summary of how consequential they are.

A third piece of evidence is the developer-side context in 831314, from the original poster:

> ✅ **VERIFIED** (as a quotation of the developer, not of Apple) — thread 831314 OP:
>
> > "Since each adapter is tied to a specific system model version, adapters have to be retrained
> > whenever the base model changes. The toolkit version page currently lists **26.0.0** as the
> > latest, noted as the last release for the OS 26 line."

So: the Adapter Training Toolkit stops at **26.0.0**, and Apple's reply — *"I'll update the page"* —
is an acknowledgement that the page was stale, not a promise of a 27 release.

### 1.2 Read the first statement again, slowly

The Frameworks Engineer's reply is doing four separate things, and it is worth separating them,
because the second half of it is the only migration guidance Apple has published anywhere.

| Clause | What it establishes |
|---|---|
| "as we announced at WWDC26" | Apple's position is that this was communicated. We could not find where. See §1.4. |
| "custom adapters are unfortunately no longer supported as of OS 27" | The withdrawal, with a version boundary. |
| "you can use the base machine-learning models that are available on people's devices" | Path 1 — stay on the system model. §6. |
| "or provide your own custom models using **Core ML or Core AI**" | Path 2 — bring the model. §7. Note *Core ML* is named alongside Core AI. |
| "**Background Assets** remains a great way to deliver custom models" | The delivery half. [Part 15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md). |

That single sentence is the whole officially-named migration path. Everything after it in this guide
is construction. §9 is where we say so in full and name what would close the gap.

Note also what is *not* in that list: **MLX**. Apple's answer names Core ML and Core AI. MLX is a
legitimate third path — it is the only one of the three where you can still actually *fine-tune* —
and an Apple Designer names it in a different thread as a way to reach devices Apple's own model
cannot (§8.1). But if you are looking for Apple to have blessed the MLX route specifically as the
adapter successor, that blessing is in a different conversation about a different question.

### 1.3 Why "two forum replies" is stronger evidence than it sounds

The series precedence order puts Apple-staff forum answers *above* WWDC session transcripts, and the
series README says why: several WWDC transcript claims from this cycle are already superseded, and
custom adapters are given as the first example. This is that case, exactly.

The forum answers also corroborate each other in a way that is hard to fake:

- **Two different Apple badges.** "Frameworks Engineer" and "Apple Designer" are distinct roles that
  appear across dozens of threads in this corpus; they are not the same person posting twice.
- **Two different questions.** 829108 is a debugging thread about a delivery failure; 831314 is a
  tooling-version question. Neither poster asked "are adapters going away." Both got told.
- **A third, non-verbal signal.** The toolkit version page stops at 26.0.0, and Apple's own reply
  concedes the page needs updating.
- **An architectural signal.** Adapters were pinned to a specific base-model version, and OS 27 both
  rebuilt the on-device model *and* forked it into two variants — **AFM 3 Core** and **AFM 3 Core
  Advanced**, split by hardware tier (thread 832910, Apple Designer, accepted answer). An adapter
  that must be retrained per base-model version, against a base model that has just become two base
  models on a hardware-dependent split, is a maintenance story that does not have a happy ending.
  This does not *prove* the withdrawal, but it makes it legible.

### 1.4 What the evidence does *not* include — and this matters

Be precise about the shape of the hole. As of **2026-07-27**, in a corpus that includes 16 WWDC26 /
Meet-with-Apple transcripts, six Apple documentation articles, four forum topic captures with ~45
live thread fetches, and 17 cloned repositories:

> 🔴 **GAP — there is no Apple document that announces this.** Specifically absent:
>
> - **No documentation page.** No `/documentation/foundationmodels/…` article, deprecation notice or
>   migration guide covering adapters is in our corpus.
> - **No release-note entry.** The iOS/iPadOS 27 release notes' Foundation Models section is quoted
>   in our corpus for the Private Cloud Compute simulator issue (177684296). Adapters do not appear.
> - **No WWDC26 session.** The Frameworks Engineer says "as we announced at WWDC26." Our three
>   Foundation Models transcripts do not contain it. The 2026 code-along **explicitly defers**
>   adapters as an advanced topic it will not cover (`notes/transcripts/fm-core.md:2068-2071`), which
>   is a strange thing to do in the year you remove them, and the researcher who read those
>   transcripts recorded adapters as covered by "only forum evidence"
>   (`notes/transcripts/fm-core.md:2258`).
> - ~~**No deprecation attribute we can quote.**~~ ✅ **RESOLVED 2026-07-29 — there is one now, and
>   it is exactly the attribute §1.4 asked for.** The 27.0 beta `FoundationModels.swiftinterface`
>   (Xcode 27.0 beta `27A5228h`, captured to
>   `notes/sdk-interfaces/FoundationModels-27.0-macos.swiftinterface`) marks
>   `SystemLanguageModel.Adapter` and its working surface — `init(fileURL:)`, `init(name:)`,
>   `compile()`, `compatibleAdapterIdentifiers(name:)` — as
>   **`@available(iOS, deprecated: 26.4, obsoleted: 27.0)`** (macOS and visionOS likewise;
>   `27.0:509-551`), and `SystemLanguageModel.init(adapter:guardrails:)` as **`obsoleted: 27.0`**
>   (`27.0:395-400`). §2 unpacks what `obsoleted:` does to your build. The captured **26.5**
>   interface has no deprecation on any of it (`26.5:578-671`) — the marks arrived with the 27 SDK,
>   and they back-date the deprecation to **26.4**, the release that swapped the base model.
>
> **What is still missing, as of the 2026-07-29 check:** the *prose* half — a documentation page
> with a deprecation banner, a release-note entry, or a WWDC26 transcript containing the
> announcement. The header now says it; no Apple document does. An updated Adapter Training Toolkit
> page would also close it (Apple said they would update it — check whether they have).
>
> **Safe default:** treat the withdrawal as fact and plan the migration. You can now tell your team
> it is **in the SDK** — quote the `obsoleted: 27.0` attribute — but still not that it is
> "documented," because the prose half remains absent, and someone will go looking.

### 1.5 The one thing to take from §1

When this guide was first written, you were being asked to re-architect a feature on the strength of
two forum replies. As of 2026-07-29 the evidence is materially better: two forum replies **plus the
27 SDK's own `deprecated: 26.4, obsoleted: 27.0` annotations** on every adapter symbol (§1.4). The
withdrawal is now compiler-enforceable fact; only the prose announcement is still missing. The rest
of this guide is written to the same standard as before: everything Apple actually said or shipped
is quoted and marked ✅, everything inferred is marked 🟡, and every place where this guide is
stitching together an answer Apple has not given is marked 🔴 with the stitching shown.

---

## 2. What "no longer supported" concretely means

"No longer supported" is doing a lot of work in a five-word forum reply. Here is the claim-by-claim
breakdown, each with its own marker, because the differences between these rows are the difference
between "you have six months" and "your next release is broken."

| # | Claim | Marker | Basis |
|---|---|---|---|
| 1 | Custom adapters are not supported as of OS 27 | ✅ **VERIFIED** | Threads 829108 and 831314, two Apple staff |
| 2 | The Adapter Training Toolkit's last release is **26.0.0**, for the OS 26 line | ✅ **VERIFIED** | Toolkit version page as quoted by 831314's OP; Apple's reply concedes the page is stale |
| 3 | There will be no 27 toolkit | ✅ **VERIFIED** | *"Sorry, we're no longer supporting adapters as of OS 27"* in direct answer to *"updated version for OS 27?"* |
| 4 | Apple's named replacement is Core ML **or** Core AI for the model, Background Assets for delivery | ✅ **VERIFIED** | Thread 829108, quoted in full in §1.1 |
| 5 | Each adapter was pinned to a base-model version and required retraining when the base model changed | ✅ **VERIFIED** (developer statement, uncontradicted by Apple in-thread) | Thread 831314 OP |
| 6 | The `.fmadapter` bundle format existed and was the input to packaging | ✅ **VERIFIED** | `--adapter-path aurelius1.fmadapter` in the working command from thread 823148 |
| 7 | `SystemLanguageModel.Adapter(name:)` existed and required the asset pack to be downloaded first | ✅ **VERIFIED** | Apple Frameworks Engineer, thread 829108 (quoted §4.2) |
| 8 | An adapter shipped in a 26.x build still works on a device running 26.x | 🟡 **RECONSTRUCTED** | Nothing withdrew it *from 26*; the statements are all "as of OS 27", and the captured **26.5 SDK interface carries no deprecation on any adapter symbol** (`26.5:578-671`, checked 2026-07-29). Runtime behaviour on 26.x is still untested by anyone in this corpus. |
| 9 | An adapter shipped in a 26.x build still works on a device that **upgrades to 27** | 🔴 **GAP** | Nobody has published a test. See the callout below. The 27 SDK's `obsoleted: 27.0` marks (§1.4) are about *compiling*, not about what the 27 runtime does with an already-built binary. |
| 10 | `xcrun ba-package foundation-models package` still produces a loadable pack under Xcode 27 | 🔴 **GAP** — first half now checked | ✅ The subcommand **exists** in the Xcode 27.0 beta (`27A5228h`, run 2026-07-29): `ba-package foundation-models package` is live (`ba-package` 2.0-beta), hidden from the top-level subcommand list but fully functional with `--asset-pack-id` / `--platforms` / `--adapter-path` / download-policy flags / `--output-path`. Whether the **27 runtime consumes its output** remains unverified — and the `obsoleted:` marks on the consuming API make it doubtful for 27-linked apps. |
| 11 | ~~Building against the 27 SDK produces a compiler error or deprecation warning for adapter APIs~~ ✅ **RESOLVED 2026-07-29** | The 27.0 interface answers precisely: with a **27.0 deployment target you get a hard compile error** (`obsoleted: 27.0`); with a lower deployment target you get **deprecation warnings** (`deprecated: 26.4`) on `Adapter` and its members (`27.0:395-400, 509-551`). The `AssetError` family is deprecated but *not* obsoleted (`27.0:553-605`), so 26-era catch blocks still compile. See the revised callout below. |
| 12 | `LanguageModelSession.GenerationError` is deprecated in 27.0 | ✅ **VERIFIED** | Apple Frameworks Engineer's own code comment, thread 831404. **This is a different thing from the adapter removal** — see §2.3. |

### 2.1 ⚠️ The three unknowns, and what to do about each

> 🔴 **GAP — does a 26.x-shipped adapter survive the user's upgrade to 27?**
>
> **What is unknown:** whether `SystemLanguageModel.Adapter(name:)` on a device that upgraded from
> 26.x to 27.0 (a) resolves and runs, (b) throws, or (c) resolves against a base model it was not
> trained for and produces degraded output with no error. All three are plausible. The mechanism —
> adapters pinned to a base-model version, and OS 27 shipped a rebuilt and now *forked* base model —
> makes (b) or (c) more likely than (a), and (c) is the one that should worry you.
>
> **What would resolve it:** one device test. Take a 26.x build with a working Apple-hosted adapter
> asset pack, install it on a device running 27.0, and log the result of adapter construction and of
> ten fixed prompts. This is a half-day of work and nobody in our corpus has published it.
>
> **Safe default:** assume (c) — silently degraded output. Gate adapter use on the OS version in
> your *shipping 26.x build* now, so that a user who upgrades to 27 falls back to the
> non-adapter path rather than to something that looks like it is working. §10.2 has the code.

> 🔴 **GAP — does the packaging CLI still work? (Half-closed 2026-07-29.)**
>
> **Now known:** `xcrun ba-package foundation-models package` **exists and runs** in the Xcode 27.0
> beta (`27A5228h`) — checked directly on this machine, `ba-package` version `2.0-beta`. The
> `foundation-models` subcommand is hidden — it does not appear in `ba-package --help`'s subcommand
> list, and its own help page describes it as *"Commands that the Foundations Models toolkit
> invokes"* (sic, Apple's typo) — but
> `ba-package foundation-models package --help` prints a full usage: `--asset-pack-id`,
> `--platforms iOS|macOS|tvOS|visionOS`, `--adapter-path`, the
> `--essential`/`--prefetch`/`--on-demand` download-policy flags, `--installation-event-types`, and
> `--output-path`.
>
> **Still unknown:** whether the **27 runtime consumes its output**. Tool survival is weak evidence —
> the consuming API (`Adapter(name:)`, `init(adapter:)`) is `obsoleted: 27.0` in the same beta's
> SDK, so no 27-built binary can even reach it; the open question is only about 26-built binaries on
> upgraded devices (row 9).
>
> **What would resolve the rest:** an end-to-end install test — pack, upload, download on a 27.0
> device, construct the adapter from a 26-built binary.
>
> **Safe default:** unchanged — keep an Xcode 26 toolchain on the machine that builds your 26.x
> maintenance releases, and do not plan to rebuild adapter packs under Xcode 27.

> ⚠️ **SILENT FAILURE — revised 2026-07-29, because the compiler now *does* tell you. Partly.**
>
> When this guide was first written, no adapter diagnostic was attested either way. The 27.0 beta
> interface settles it (row 11): rebuild with Xcode 27 and you get **deprecation warnings**
> (`deprecated: 26.4`) on every adapter call site while your deployment target is below 27, and
> **hard errors** (`obsoleted: 27.0`) the moment you raise it to 27.0. So the "everything compiles
> clean and nothing was flagged" version of this trap is gone.
>
> The trap that **remains** is runtime, and it is the one that matters for a dual-target app: at a
> sub-27 deployment target your adapter code still compiles (warnings are not errors, and warning
> fatigue is real — they sit right next to the `GenerationError` deprecation warnings from the
> *other* migration, §2.3). Ship that binary to a device that upgrades to 27 and the adapter either
> silently stops being applied or is applied against a base model it was not trained for (row 9 —
> still untested). Your outputs shift. Nothing throws. You find out from a review that says the app
> "got dumber."
>
> **The countermeasure is not the compiler, it is an evaluation set.** §6.7 and
> [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md). This is Apple's own recommendation for a related problem —
> asked directly about model versioning, a Frameworks Engineer confirmed there is **no pinning API
> and no version-retrieval API**, and named the Evaluations framework as the mitigation
> (thread 833642).

### 2.2 A grep you can run right now

Before anything else, find out how much of this applies to you. From the root of your project:

```bash
# Swift call sites
grep -rn "SystemLanguageModel\.Adapter\|adapter:" --include="*.swift" .

# The bundle format and any packaging scripts
find . -name "*.fmadapter" -o -name "produce_asset_pack.py" -o -name "*.aar"

# The entitlement — on the app target AND on any asset downloader extension
grep -rn "com.apple.developer.foundation-model-adapter" --include="*.entitlements" .

# The Background Assets plist keys that accompanied adapter delivery
grep -rn "BAHasManagedAssetPacks\|BAUsesAppleHosting\|BAAppGroupID" --include="*.plist" .

# Your 26-era error handling, which is a separate migration (17.3)
grep -rn "GenerationError" --include="*.swift" .
```

Everything the first four commands find is on the historical path. §3 tells you what each piece was
for; §5 onward tells you what replaces it.

### 2.3 Two migrations that arrived together and are not the same migration

This trips people up, so it is worth being explicit. In the 26 → 27 window you are hit by:

- **The adapter withdrawal** — a *capability* removed, with no compiler diagnostic, evidenced only
  by forum replies. This guide.
- **The error-taxonomy rewrite** — `LanguageModelSession.GenerationError` deprecated in favour of
  `LanguageModelError`, *with* a compiler diagnostic, and with the delightful property that a
  rebuild can silently change which `catch` clause fires.
  [17.3](03-error-taxonomy-migration.md).

They interact in exactly one place: the errors your adapter code throws today
(`compatibleAdapterNotFound` and friends) belong to the old taxonomy, so if you are keeping a 26.x
branch alive you are maintaining old error handling for a removed feature. Do not try to modernise
that error handling on the 26 branch. Freeze it. §10.4.

---

## 3. The historical record: the 26.x adapter pipeline

This section exists for two kinds of reader.

The first is shipping a 26.x build today and will keep shipping it for months. You need this because
**it is not written down anywhere else in one place**. The packaging command below was discovered by
a developer reading the Adapter Training Toolkit's own `produce_asset_pack.py`, posted to the forums,
and marked "Recommended" by Apple. It appears in no Apple documentation page, no WWDC transcript, and
no sample project in our corpus.

The second is trying to understand what they are migrating *away from*, so that they can tell which
pieces of the replacement are new complexity and which are complexity they already had. A surprising
amount of the Core AI path in §7 will look familiar: a versioned artifact, a Background Assets pack,
an availability check before use. The adapter pipeline was already that shape.

> ⚠️ Everything in this section is **26.x history**. Do not build new work on it. Rows 9, 10 and 11
> of §2's table are the open questions about how much of it still functions under 27; the safe
> defaults are in §2.1.

### 3.1 The shape of the thing

```
        TRAINING (Adapter Training Toolkit, last release 26.0.0)
        ────────────────────────────────────────────────────────
           your data  ──►  toolkit  ──►  MyAdapter.fmadapter
                                          (pinned to one base-model version)
                                                  │
        PACKAGING                                 ▼
        ─────────      xcrun ba-package foundation-models package
                          --adapter-path MyAdapter.fmadapter
                          --asset-pack-id fmadapter-MyAdapter-1234567
                          --output-path ./MyAdapter.aar
                                                  │
        HOSTING                                   ▼
        ───────        upload .aar via Transporter  ──►  Apple-hosted managed asset pack
                       (⚠ manifest "onDemand": null → ITMS-91140; see §3.5)
                                                  │
        RUNTIME                                   ▼
        ───────   AssetPackManager.ensureLocalAvailability(of:requireLatestVersion:)
                                                  │
                    SystemLanguageModel.Adapter(name: "MyAdapter")
                                                  │
                              LanguageModelSession(...)
```

Five moving parts, four of which could fail silently, and one of which (`ensureLocalAvailability`)
was the single missing call behind the most-reported adapter bug. §4.

### 3.2 The Swift API surface

Everything here is 26.x. The markers are about *spelling confidence*, not about whether the feature
worked — it demonstrably worked; people shipped with it.

```swift prelude:platform-target
import FoundationModels
import BackgroundAssets

// ── Construction from an Apple-hosted managed asset pack ────────────────────
// ✅ VERIFIED spelling — quoted by an Apple Frameworks Engineer, thread 829108;
//    ✅ SDK-verified: `public init(name: String) throws` (26.5:664).
let adapter = try SystemLanguageModel.Adapter(name: "FiutoAdapter")

// ── Discovering which packs are compatible with the CURRENT base model ──────
// ✅ VERIFIED — developer code in thread 823148, in a reply Apple marked "Recommended";
//    ✅ SDK-verified (26.5:670), alongside its cleanup sibling
//    `static func removeObsoleteAdapters() throws` (26.5:671).
let ids = SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name: "FiutoAdapter")
// ids == ["fmadapter-FiutoAdapter-1234567"]

// ── Construction from a local file, for development ─────────────────────────
// ✅ VERIFIED as a real API — thread 823001 reports it by name (in the course of
//    reporting that it leaks ~100 MB per call; see §4.4);
//    ✅ SDK-verified: `public init(fileURL: URL) throws` (26.5:663).
let localAdapter = try SystemLanguageModel.Adapter(fileURL: adapterURL)
```

> ✅ **SDK-verified — how the adapter reached the session.** This guide previously carried
> `SystemLanguageModel(adapter:)` as reconstructed from a negative citation, its declaration never
> seen. The 26.5 interface (`notes/sdk-interfaces/FoundationModels-26.5-macos.swiftinterface:585`,
> read 2026-07-29) now shows it exactly:
>
> ```swift
> convenience init(adapter: SystemLanguageModel.Adapter,
>                  guardrails: SystemLanguageModel.Guardrails = .default)
> ```
>
> — so `SystemLanguageModel(adapter: adapter)` was the real spelling, with `guardrails:` defaulted.
> The same interface also settles the type's other members: `Adapter` is a struct with
> `creatorDefinedMetadata: [String: Any]` (`26.5:652-657`) and a `@concurrent func compile() async
> throws` (`26.5:666`). In the **27.0** interface the initializer still appears — annotated
> `obsoleted: 27.0` (`27.0:395-400`), which is the header-level sunset of §1.4.
>
> ```swift
> // ✅ The historical 26.x wiring, now header-confirmed. Do not write this in new code.
> let model = SystemLanguageModel(adapter: adapter)
> let session = LanguageModelSession(model: model)
> ```
>
> **Naming hazard worth flagging:** one summary in our own research corpus renders the local-file
> constructor as `SystemLanguageModel(fileURL:)` rather than `SystemLanguageModel.Adapter(fileURL:)`
> (`notes/02-lead-agent-corpus-gaps-filled.md:149`). The interface confirms the latter: `fileURL:`
> is an initializer on **`Adapter`**, not on the model. If you are reading old code and see either,
> they are the same feature. Nobody should be writing new code against either.

### 3.3 Why every adapter carried a version pin

This is the design fact that makes the withdrawal legible, and it is also the reason the
`compatibleAdapterIdentifiers(name:)` call above had to exist at all.

> ✅ **VERIFIED** — thread 831314, OP: *"Since each adapter is tied to a specific system model
> version, adapters have to be retrained whenever the base model changes."*

A LoRA adapter is a low-rank delta applied to specific weight matrices of a specific base model. If
the base model's weights change — a new AFM revision in a point release — the delta is being added
to matrices that are no longer the matrices it was fitted against. So the platform had to keep, per
adapter *name*, a set of packs each compatible with a particular base-model version, and
`compatibleAdapterIdentifiers(name:)` was how you asked which of them applied *right now*, on *this*
device. The returned identifier had the shape `fmadapter-<Name>-<7 digits>`
(✅ verified, thread 823148).

Now stack the 27 changes on top of that contract:

- The on-device model was rebuilt for the 27 cycle.
- It **forked into two models** — **AFM 3 Core** and **AFM 3 Core Advanced** — split by hardware
  tier, with an exact device list published by an Apple Designer in thread 832910 (accepted answer).
  Devices with the Advanced variant: iPhone Air, iPhone 17 Pro, iPhone 17 Pro Max, iPad (M4) or
  later with at least 12 GB of unified memory, Mac (M3) or later with at least 12 GB, Apple Vision
  Pro (M5). Everything else gets AFM 3 Core.
- Apple states plainly that there is **no model pinning API and no version-retrieval API**
  (thread 833642, Frameworks Engineer).

Read those together: a per-base-model-version artifact, against a base model that now varies by
device tier as well as by OS revision, with no API to ask which version you are talking to. That is
a combinatorial retraining obligation with no way for the developer to enumerate the combinations.
This is not a justification — Apple has not offered one — but it is the most coherent reading of
why the feature ended.

### 3.4 Delivery: the entitlement, the plist keys, the extension

Adapters shipped as **Background Assets managed asset packs**, hosted by Apple. That required a
specific and almost entirely undocumented configuration.

> ✅ **VERIFIED** — all of the following from thread 823148, in a reply Apple marked "Recommended".

The entitlement, required **on the app target *and* on the asset downloader extension**:

```
com.apple.developer.foundation-model-adapter
```

The `Info.plist` keys:

```xml
<key>BAHasManagedAssetPacks</key><true/>
<key>BAUsesAppleHosting</key><true/>
<key>BAAppGroupID</key><string>group.com.example.shared</string>
```

The extension point: **`StoreDownloaderExtension`**.

Note the shape of that entitlement name — `foundation-model-adapter`, singular, purpose-built. It is
not a general "ship a model" entitlement. It exists for this feature and nothing else, which is one
more reason not to expect it to be reused by the Core AI path in §7. If you have it in an
`.entitlements` file, it is dead weight the moment you drop the adapter code, and you should remove
it in the same release rather than leave a stale capability request on the target.

### 3.5 The packaging command, and the manifest defect

The command, verbatim from thread 823148:

```bash
xcrun ba-package foundation-models package \
  --adapter-path aurelius1.fmadapter \
  --asset-pack-id fmadapter-aurelius1-9799725 \
  --output-path ./aurelius1.aar \
  --platforms iOS \
  --on-demand
```

Four findings from that thread, all ✅ verified as developer-reported and Apple-endorsed:

1. **The generic subcommand does not work.** `xcrun ba-package package` — the ordinary Background
   Assets packaging command — produces a pack that *"the FoundationModels runtime will not
   recognize."* The Foundation Models-specific subcommand is
   `xcrun ba-package foundation-models package`. The developer found it by reading the toolkit's
   `produce_asset_pack.py`. It is documented in no Apple page in our corpus.
2. **The generated manifest is invalid for upload.** It emits `"onDemand": null`, and Transporter
   rejects the upload with **ITMS-91140**.
3. **The workaround** is to extract the `.aar`, edit `manifest.json` to change `"onDemand": null` to
   `"onDemand": {}`, repack, and upload.
4. **After that it works**: internal TestFlight delivery succeeds and `statusUpdates` fires
   `.began` / `.downloading(progress)` / `.finished`.

> ⚠️ **SILENT FAILURE — the wrong subcommand produces a valid pack that the runtime ignores.**
> This is the archetypal defect of this whole area. `xcrun ba-package package` exits zero. It
> produces a well-formed `.aar`. Transporter accepts it (modulo the `onDemand` defect). The pack
> downloads on the device, and `AssetPackManager` reports it as available. And then the Foundation
> Models runtime does not recognise it as an adapter, so `SystemLanguageModel.Adapter(name:)` fails
> to find a compatible adapter — with an error that describes the *symptom* (`compatibleAdapterNotFound`)
> and gives you no hint that the cause was a packaging subcommand you chose forty minutes of build
> time ago. §4 is the other half of this failure.

### 3.6 The runtime sequence, complete

Putting §3.2, §3.4 and §3.5 together, here is what a working 26.x adapter load looked like. This
compiles against the 26 SDK; it is here as reference for a maintenance branch, not as a pattern to
adopt.

```swift prelude:platform-target
import FoundationModels
import BackgroundAssets

/// 26.x ONLY. Custom adapters are discontinued as of OS 27 — see §1.
/// Kept here as the historical record of a working load sequence.
@available(iOS 26.0, macOS 26.0, *)
enum LegacyAdapterLoader {

    enum LoadFailure: Error {
        case noCompatiblePack          // compatibleAdapterIdentifiers returned []
        case notDownloaded(Error)      // ensureLocalAvailability threw
        case adapterConstruction(Error)
    }

    /// Resolve, ensure-download, and construct — in that order. The order is the whole point.
    static func loadAdapter(named name: String) async throws -> SystemLanguageModel.Adapter {

        // 1. Which packs are compatible with the base model THIS DEVICE is running right now?
        //    ✅ VERIFIED API — thread 823148.
        let identifiers = SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name: name)
        guard let packID = identifiers.first else {
            // No pack was trained against the base model on this device. On 26.x this happened
            // after an OS point release shipped a new AFM revision before you shipped a retrained
            // adapter. There is no recovery except falling back to the base model.
            throw LoadFailure.noCompatiblePack
        }

        // 2. Force the download if the pack's policy is "on demand".
        //    ✅ VERIFIED — this is the exact call Apple named as the fix in thread 829108.
        do {
            try await AssetPackManager.ensureLocalAvailability(
                of: packID,
                requireLatestVersion: true
            )
        } catch {
            throw LoadFailure.notDownloaded(error)
        }

        // 3. Only now construct the adapter. Step 3 without step 2 is the bug in §4.
        do {
            return try SystemLanguageModel.Adapter(name: name)
        } catch {
            throw LoadFailure.adapterConstruction(error)
        }
    }

    /// Optional: surface download progress to the user.
    /// ✅ VERIFIED shape — thread 823148.
    static func observeDownload(of packID: String) async {
        for await status in AssetPackManager.shared.statusUpdates(forAssetPackWithID: packID) {
            print("asset pack \(packID): \(status)")
        }
    }
}
```

> 🟡 **RECONSTRUCTED — the last mile.** How the resulting `SystemLanguageModel.Adapter` was handed to
> a session is the one link in this chain we cannot quote. See the callout in §3.2. If you have a
> working 26.x build, the answer is in your own source; trust that over anything written here.

### 3.7 Two adapter costs that show up in the thread titles

Our corpus enumerates the full Foundation Models forum topic. Two thread *titles* describe adapter
costs that nobody wrote up in detail, and they are worth knowing because they change the honest
accounting of what an adapter was buying you:

- **Thread 806779 — "Context window 90% of adapter model full after single user prompt."**
  🟡 The title is verified (it is in our thread enumeration); the contents are not in our corpus.
  If the effect is real, it means an adapter consumed a large fraction of a 4,096-token budget
  before the user typed anything — which would make the adapter and the context window direct
  competitors for the same scarce resource.
- **Thread 805970 — "Training adapter, it won't call my tool."**
  🟡 Title verified, contents not captured. Consistent with the general result that task-specific
  fine-tuning can degrade a base model's general instruction-following, including tool calling.

> 🔴 **GAP.** Neither thread's body is in our corpus and neither has an Apple answer we have read.
> **What would resolve it:** fetching `developer.apple.com/forums/thread/806779` and `.../805970`.
> **Safe default:** do not cite either as a measured cost. They are listed here so that a reader
> re-deriving "was my adapter worth it" knows these reports exist, not as evidence of a number.

The reason to raise them at all: part of migrating well is being honest about whether the thing you
are losing was as good as you remember. §5 and §6.7 turn that into a measurement rather than a
memory.

---

## 4. `compatibleAdapterNotFound`, and the leak underneath it

Thread **829108** is the thread where Apple announced the withdrawal. It is worth understanding
*why* it existed, because the bug it was opened about is the exact bug you will hit if you are still
maintaining a 26.x adapter build — and because the shape of the failure is a preview of what
delivering *any* model asset feels like.

### 4.1 The symptom

> ✅ **VERIFIED** — thread 829108, *"Adapter Problem - `compatibleAdapterNotFound`"*, `alex_und3r`,
> 2026-06-04, 6 replies. The failure, as reported:
>
> - The adapter loads correctly **on device** when constructed from a local file URL.
> - The same adapter, delivered as an **Apple-hosted managed asset pack** through **TestFlight**,
>   fails with **`compatibleAdapterNotFound`**.
>
> The error's declaration is now ✅ **SDK-verified** (`26.5:676-698`): `Adapter.AssetError` is an
> enum with exactly three cases — `.invalidAsset(_:)`, `.invalidAdapterName(_:)`,
> `.compatibleAdapterNotFound(_:)` — each carrying a one-field `Context(debugDescription: String)`,
> the same payload poverty as the 26-era `GenerationError.Context`
> ([17.3 §4.5](03-error-taxonomy-migration.md)). In the 27.0 interface the family survives,
> deprecated 26.4 but **not** obsoleted (`27.0:553-605`) — so a dual-target codebase can keep these
> catch arms compiling.

Read that carefully, because the shape of it is what makes it expensive:

| | Local file URL | Apple-hosted managed asset pack via TestFlight |
|---|---|---|
| Same `.fmadapter` bytes | ✅ | ✅ |
| Same device | ✅ | ✅ |
| Same base model | ✅ | ✅ |
| Same code path constructing the adapter | ✅ | ✅ |
| **Works** | **yes** | **no** |

Everything the developer controls is identical. The only difference is the delivery mechanism, and
the delivery mechanism is the part with no documentation. This is why the thread ran to six replies.

There is a sibling thread with the same root shape: **823148**, *"Apple managed asset pack for
FoundationModels adapter on Testflight does not download (`statusUpdates` silent)"* — same delivery
path, and the failure there is that the download never begins and the status stream says nothing at
all. That thread is where the packaging command in §3.5 came from.

### 4.2 Apple's answer: one missing call

> ✅ **VERIFIED** — thread 829108, **Frameworks Engineer (Apple)**:
>
> > "Based on the code in the screenshots that you posted, it looks like you're missing a call to
> > `AssetPackManager.ensureLocalAvailability(of:requireLatestVersion:)`. When you set an asset
> > pack's download policy to 'on demand', you're telling the system that it shouldn't download the
> > asset pack automatically. `SystemLanguageModel.Adapter(name:)` expects that the asset pack
> > already be downloaded before you call it. To fix the issue here, call
> > `ensureLocalAvailability(of:requireLatestVersion:)` and wait for it to return successfully before
> > constructing an `Adapter` instance."

So the mechanism is:

1. You packaged with `--on-demand` (as the working command in §3.5 does).
2. On-demand means the system will not fetch the pack until you ask.
3. `SystemLanguageModel.Adapter(name:)` does **not** ask. It expects the bytes to already be local.
4. It finds no local pack, and reports that no compatible adapter exists.

And that is the crux:

> ⚠️ **SILENT FAILURE — the error names the wrong thing.**
>
> `compatibleAdapterNotFound` is a **compatibility** word for a **download-state** problem. The
> adapter is perfectly compatible. It is simply not on the device yet. Every instinct that error
> triggers is wrong: you go and check your base-model version, you re-run
> `compatibleAdapterIdentifiers(name:)`, you consider retraining, you wonder whether the OS point
> release moved the base model under you. The actual answer is one missing `await`.
>
> The local-file path works because the bytes are, by construction, already local. So the failure
> only appears in the environment where it is most expensive to debug — a TestFlight build on a real
> device, where you cannot set a breakpoint and the packaging step takes minutes.
>
> **The generalisable lesson, which outlives adapters:** when you deliver a model as an asset pack,
> the *availability* of the asset and the *compatibility* of the asset are two different questions,
> and the API you are calling may only be able to answer one of them while reporting failures in
> the vocabulary of the other. §7.5 and
> [Part 15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
> carry this forward into the Core AI world: check availability explicitly, before you construct
> anything, and give that check its own error case so it never gets confused with a model problem.

### 4.3 The fixed sequence

The correct ordering — availability first, construction second — is what §3.6's `LegacyAdapterLoader`
encodes, and it is worth restating as a rule because it survives the migration:

```
resolve identifier  →  ensure local availability  →  await success  →  construct
```

Never construct-and-catch. `catch` gives you a compatibility error for a download problem, and by
then you have thrown away the information about which of the two it was.

If you are keeping a 26.x branch alive, this is the one change worth making to it: split the failure
into two distinct cases so your telemetry can tell you which is happening in the field.

```swift compile:27
// 26.x maintenance branch. Two failures, two error cases, two dashboards.
enum AdapterFailure: Error {
    case packUnavailable(id: String, underlying: Error)   // a DOWNLOAD problem
    case noCompatiblePack(name: String)                   // a VERSION problem
    case constructionFailed(underlying: Error)            // genuinely the adapter
}
```

The distinction stops mattering the day you finish this migration. It matters enormously on the day
you are trying to decide whether a spike in failures means Apple shipped a new base model or your
CDN had a bad afternoon.

### 4.4 ⚠️ The ~100 MB-per-call disk leak

Separate defect, same feature, and the most alarming one in the corpus. Thread **823001**:
*"`SystemLanguageModel.Adapter` leaks ~100MB of irrecoverable APFS disk space per call."*

> ✅ **VERIFIED** — thread 823001, developer reports corroborated by an Apple reply.
>
> - **Symptom:** each `SystemLanguageModel.Adapter(fileURL:)` call leaks **~100 MB**. 300 calls ≈
>   30 GB. One reporter reached ~239 GB; another ~104 GB across 645 clones.
> - **Mechanism:** every invocation writes `lora.part.bin` + `metadata.json` into a **new,
>   non-content-addressed hash directory** under
>   `/private/var/db/AppleIntelligencePlatform/AppModelAssets/`, written by
>   `TGOnDeviceInferenceProviderService`. **No garbage collection, no deduplication.**
> - **Why it looks like filesystem corruption:** that path is **SIP-protected**. `sudo ls` and
>   `sudo find` return "Operation not permitted", so `du` cannot see it. Disk space vanishes and
>   nothing in userspace can account for it.
> - **Apple's position**, Apple Designer: *"We've identified this is a current bug specific to
>   command line tools. You will see this adapter memory leak from a CLI on macOS, but NOT if you
>   load the adapter into a running Swift app."* — **disputed in-thread** by a second reporter who
>   observed the same growth from a SwiftUI app run out of Xcode.
> - Feedback: **FB22523518**. Environment: macOS 26.4.1, MacBook Air M4.

This is a silent failure with a physical consequence: the machine runs out of disk and the developer
concludes their APFS volume is damaged. Recovery required booting to Recovery Mode, because the path
cannot be touched from a running system. The steps as posted in the thread:

```
1. Reboot into Recovery Mode (hold Power on Apple Silicon)
2. Utilities → Terminal
3. diskutil apfs list                      # find the Data volume, e.g. disk3s5
4. diskutil mount disk3s5
5. diskutil apfs unlockVolume disk3s5
6. ls /Volumes/Data/private/var/db/AppleIntelligencePlatform/AppModelAssets/ | wc -l
7. rm -rf /Volumes/Data/private/var/db/AppleIntelligencePlatform/AppModelAssets/*
8. Reboot
```

> ⚠️ Reproduced here because a developer who spent an adapter-training summer on a laptop may still
> be carrying tens of gigabytes of orphaned clones, and will never find them with ordinary tools.
> **`rm -rf` from Recovery Mode on a system path is a serious operation.** Read the whole line
> before you run it, confirm the volume identifier from step 3 rather than copying `disk3s5`, and
> have a backup. This is quoted from a developer forum thread, not from Apple documentation, and it
> is offered as a record of what people did rather than as a recommendation.

> 🔴 **GAP — current status unknown.** Whether this leak persists on 27.0, and whether the
> `AppModelAssets` directory is cleaned up when a device upgrades to an OS where adapters no longer
> function, is **unverified as of 2026-07-27**. **What would resolve it:** a disk-usage measurement
> across an upgrade on a machine known to have accumulated clones. **Safe default:** if you were an
> adapter developer on 26.x, check that directory's clone count before you assume your disk is
> healthy — and note that you cannot check it without Recovery Mode.

### 4.5 The sibling failure: a download that never starts and never complains

Thread **823148** — the one that produced the packaging command in §3.5 — was opened for a different
symptom, and it is the one worth carrying into whatever you build next.

> ✅ **VERIFIED** — thread 823148, title: *"Apple managed asset pack for FoundationModels adapter on
> Testflight does not download (`statusUpdates` silent)."*

Read the parenthetical. The developer was observing `AssetPackManager.shared.statusUpdates(forAssetPackWithID:)`
— the API whose entire job is to tell you what is happening — and it said **nothing at all**. Not an
error. Not a `.failed` state. Silence.

> ⚠️ **SILENT FAILURE — an observation API that emits nothing is indistinguishable from an operation
> that has not started yet.**
>
> An `AsyncSequence` that yields no elements looks exactly like an `AsyncSequence` that is about to
> yield its first element. Your `for await` loop sits there. Your progress UI shows 0%. Your
> timeout — if you wrote one — fires after some arbitrary interval and tells you nothing about why.
>
> The root cause in this case was upstream of the API entirely: the pack had been built with the
> wrong `ba-package` subcommand and/or rejected at upload because of the `"onDemand": null` manifest
> defect (§3.5), so from the device's point of view there was simply nothing to report on.
>
> **The rule this justifies, for any model-delivery code you write from here:** never wait on a
> progress stream without a deadline and a *separate* liveness check. Ask "does this pack exist and
> is it in a downloadable state" as its own question, with its own answer and its own error, before
> you start observing progress on it. The §4.3 ordering — resolve, ensure, then construct — exists
> because each step can fail in a way the next step cannot describe.

That thread also demonstrates the debugging cost of an undocumented pipeline: the resolution
involved reading a Python script inside the training toolkit, discovering a subcommand nobody had
written down, hitting a manifest bug that surfaces only at App Store upload as an opaque
**ITMS-91140**, and hand-editing JSON inside an archive. The developer solved it and posted the
answer; Apple marked the post "Recommended." That is a good outcome and it should not have taken
that.

### 4.6 What this section is really telling you

Three defects — a mis-named error, a packaging subcommand you had to reverse-engineer from a Python
script, and a leak into a directory you cannot see — all in a feature that shipped, that people
built products on, and that lasted one OS cycle.

None of that is an argument that Apple was wrong to withdraw adapters. It is an argument for how to
approach the replacement: **assume the delivery path is the risky part**, instrument it separately
from the model, and do not let a model-shaped error message convince you that you have a model
problem. That principle is the through-line from here to §7.5.

---

## 5. First, ask why you had an adapter — the decision table

The most common mistake in this migration is to treat it as a *technology* substitution: I had a
fine-tuned model, therefore I need a fine-tuned model, therefore I need MLX. That is sometimes right
and frequently a large amount of work for a result you could have had for free.

The useful question is not "what replaces LoRA." It is **"what was the adapter compensating for."**
Those are four different answers.

### 5.1 The four reasons anyone trained an adapter

**Reason A — tone, voice or style.** The base model produced correct content in the wrong register:
too chatty, too formal, not in your product's voice, not matching a house style guide. The adapter
was doing style transfer.

**Reason B — domain vocabulary.** The model did not know your terms of art: internal product names,
a specialist clinical or legal or industrial vocabulary, an ontology with specific meanings for
words that mean something else in general English. The adapter was teaching nouns.

**Reason C — structured-output reliability.** You needed JSON, or a fixed set of labels, or a
particular schema, and the base model's compliance was 90% and 90% was not enough. The adapter was
buying you format compliance.

**Reason D — a genuinely different task.** Classification into a taxonomy the model has never seen.
A transformation with no natural-language description. A capability the base model does not have and
cannot be prompted into. The adapter was doing actual learning.

Most shipped adapters were B or C, and a large fraction of C never needed an adapter in the first
place — because **guided generation with `@Generable` enforces structure at decode time**, which is
a stronger guarantee than fine-tuning can offer. Fine-tuning makes the model *more likely* to emit
your format. Constrained decoding makes any other format *unrepresentable*. If your adapter existed
to make JSON reliable, the replacement is not a model at all.

### 5.2 The decision table

| Why you trained it | Try first | Then | Last resort | What it costs you | Confidence |
|---|---|---|---|---|---|
| **A — tone / voice / style** | §6: instructions block with 2–3 worked examples, one-shot `@Generable` exemplar | §8: MLX LoRA on a small open model, which is the only remaining way to actually *fit* a style | §7: Core AI with a pre-fine-tuned checkpoint | Path 1 free; §8 costs app size + 27.0 floor + no ANE | Path 1 covers more of this than people expect — style is largely promptable |
| **B — domain vocabulary** | §6: put the vocabulary *in* the prompt, or retrieve it — RAG beats fine-tuning for facts | §6 + `SpotlightSearchTool` / your own retrieval tool | §8: LoRA if the vocabulary is genuinely structural, not just lexical | Path 1 free but spends context; 4,096 tokens is the ceiling | High. Apple's own guidance for knowledge is retrieval, not weights |
| **C — structured-output reliability** | §6: `@Generable` + `@Generable enum` — this *is* the fix | §6 with a simplified schema (smaller schemas perform better, per Apple) | — | Free. Also **reduces** prompt size | Very high. Constrained decoding is a hard guarantee, not a tendency |
| **D — a genuinely different task** | §8: MLX + `mlx-lm` LoRA/DoRA on an open checkpoint | §7: Core AI if you need ANE residency or you already own a converted model | — | Real: SDK floor, app size, memory, updates, and possibly `@Generable` | High that you need a model; §5.3 on which one |

### 5.3 Choosing between §7 (Core AI) and §8 (MLX) when you do need a model

Once you have established you genuinely need your own weights, the two remaining paths differ on
axes that have nothing to do with quality.

| | **Core AI** (§7) | **MLX** (§8) |
|---|---|---|
| Can you still fine-tune? | Not with any Apple-published on-device tool. You convert an already-trained checkpoint. | **Yes.** `mlx_lm.lora` with `--fine-tune-type {lora,dora,full}` is a shipping, documented CLI. |
| Session API preserved? | Yes — `CoreAILanguageModel` conforms to `LanguageModel`; `LanguageModelSession` unchanged | Yes — `MLXLanguageModel` likewise |
| `@Generable` / guided generation | **Depends on the engine variant.** GPU-pipelined bundles: **no**. §7.4 | Yes, via `MLXGuidedGeneration` |
| Neural Engine | Reachable — the optional `coreai-models` loader derives an ANE preference from a multi-function structure (package policy, not a framework contract)[^sample-routing-policy] | **No.** MLX is GPU/CPU |
| Named by Apple as the adapter migration path | **Yes** — "Core ML or Core AI" | No (named elsewhere, for a different question) |
| Distribution | You own it. Background Assets or your own transport | You own it. Plus a Hugging Face download path |
| Version floor | 27.0, hard | 27.0, hard, plus a second SDK gate (§8.4) |
| Apple sample code | **Zero** projects for `coreai` | None for the FM bridge specifically |

The short version: **if you need to keep training, you need MLX.** If you have a fixed checkpoint,
need the Neural Engine, or want the path Apple actually named, Core AI. If you need to keep training
*and* you need the Neural Engine, you have a problem this guide cannot solve for you, and the honest
advice is to re-read §6 and check whether the task can be reframed.

### 5.4 The option nobody puts in a table

**Ship the feature without the adaptation and measure how much worse it is.**

It is not a rhetorical suggestion. You are about to spend somewhere between a week and a quarter on
this. The cheapest possible first experiment is: take the same evaluation set, run it against the
plain `SystemLanguageModel` with a well-written instructions block and a `@Generable` return type,
and look at the number. Three things can happen:

1. It is close enough. You are done, at a cost of one afternoon, and you delete an entitlement, a
   Background Assets pipeline, an extension target, and a training job.
2. It is close but not close enough. §6 has more levers, and you now know what you are aiming at.
3. It is nowhere near. You have a real answer to §5.1 reason D, and you go to §7 or §8 with
   justification and a baseline.

All three outcomes are better than starting the port. The only way to get any of them is to have the
evaluation set, which is why §6.7 exists and why it is not optional.

---

## 6. Path 1 — prompting plus guided generation

**Try this first.** It costs one afternoon, it keeps you on the system model, and it removes every
line of distribution, entitlement and asset-pack code you currently maintain. It is also the only
one of the three paths that works on both 26 and 27, which means you can ship it *before* you drop
your 26 deployment target.

The claim is not that prompting is as powerful as fine-tuning. It is that a large fraction of
shipped adapters were compensating for a weak prompt, an unstructured output contract, or both —
and that Apple's own material says so, in the process of teaching guided generation.

### 6.1 The two mechanisms, and which one you actually need

There are exactly two levers here and they do different jobs:

**Instructions** — the persistent, developer-authored preamble that establishes persona, rules and
constraints. It is also a security boundary.

> ✅ **VERIFIED** — WWDC26 Foundation Models code-along, transcribed at
> `notes/transcripts/fm-core.md:1081-1088`, verbatim:
>
> > "**Instructions can be used to define a persona, set rules, and specify desired format for the
> > output. Instructions are provided by you, the developer, whereas prompts are typically provided
> > by the person using the app. The model is trained to obey instructions over prompts, and this
> > can help protect [against] prompt injection… As a rule, keep the instructions static and avoid
> > inserting user input into them.**"
> >
> > "**Also note that instructions are maintained throughout the session's life. Every interaction is
> > recorded in the session's transcript, and the initial instructions are always the first entry.**"

**Guided generation** — `@Generable` types, enforced at decode time.

> ✅ **VERIFIED** — same source, `notes/transcripts/fm-core.md:1435-1443`, verbatim:
>
> > "the key benefit of guided generation is that it **fundamentally guarantees structural
> > correctness**. It uses a technique called **constraint[ed] decoding** to do that."
> >
> > "This also means that **our prompts can be a lot simpler and more focused on the desired behavior
> > instead of prompting the model for specific output formats. This also tends to improve model
> > accuracy [and] allow for optimizations that speed up inference.**"

That second quote is the one that matters for this migration. Structural correctness is not
*encouraged*, it is *guaranteed* — the decoder cannot emit a token that would violate the schema. No
amount of fine-tuning gives you that, because fine-tuning shifts a probability distribution and
constrained decoding truncates it.

Full treatment of both in
[Part 2.1 (sessions and prompting)](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
and
[Part 2.2 (guided generation and streaming)](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).
What follows is the migration-shaped subset.

### 6.2 Apple's own demonstration: the prompt gets *smaller*

The most useful evidence that this path is real is that Apple's code-along, having introduced
`@Generable`, then goes back and **deletes** prompt text.

> ✅ **VERIFIED** — `notes/transcripts/fm-core.md:1459-1464`, verbatim:
>
> > "the final change we'll need to make is to **remove additional structural guidance that we are
> > providing in our instructions**. Notice how we say 'each day needs an activity, hotel and
> > restaurant, always include a title, short description, day by day'. **But all of this information
> > is already in our itinerary `@Generable` struct. We don't need to provide it again in our
> > instructions. So… another benefit of using generables is you can make your prompts much simpler,
> > which can help improve performance as well.**"

After that edit, the instructions in Apple's demo collapse to approximately one sentence:

```swift compile:27
let instructions = "Your job is to create an itinerary for the user."
```

If your adapter existed to make the model reliably produce your shape, the shape belongs in a Swift
type, not in weights and not in prose. This is §5.1 reason C, and it is the single highest-yield
substitution in this guide.

### 6.3 The rewrite, worked end to end

Take a concrete adapter-shaped task: extracting structured incident reports from free-text field
notes. On 26.x this was an adapter — the base model would produce prose, drift on the severity
vocabulary, and occasionally return four fields instead of five.

**Before — 26.x, adapter plus a prompt doing structural work:**

```swift prelude:guide-context
import FoundationModels

// 26.x. Adapter carrying both the vocabulary and the format contract.
@available(iOS 26.0, macOS 26.0, *)
func legacyExtract(from note: String) async throws -> String {
    let adapter = try await LegacyAdapterLoader.loadAdapter(named: "IncidentExtractor")
    let model = SystemLanguageModel(adapter: adapter)      // 🟡 spelling — see §3.2

    let session = LanguageModelSession(model: model) {
        """
        Extract an incident report from the field note.
        Always return JSON with exactly these keys: summary, severity, location,
        equipment, followUpRequired. severity must be one of: minor, moderate,
        major, critical. Do not add commentary. Do not wrap in markdown fences.
        Return only the JSON object. Every key must be present even if empty.
        """
    }
    return try await session.respond(to: note).content   // a String you then parse, and hope
}
```

Count what that prompt is spending tokens on: key names, key count, an enum's cases, four
negative instructions about formatting, and a completeness requirement. All of it is type
information expressed as English.

**After — 27.0, no adapter, the contract in the type system:**

```swift compile:27
import FoundationModels

/// The severity vocabulary, as a type. The decoder cannot emit anything else.
/// ✅ VERIFIED pattern — `@Generable enum` is Apple's demonstrated mechanism for a
/// fixed, compile-time-known case set (`notes/transcripts/fm-core.md:1396-1422`).
@Generable
enum Severity {
    case minor
    case moderate
    case major
    case critical
}

@Generable
struct IncidentReport {
    @Guide(description: "One sentence, past tense, no speculation.")
    var summary: String

    var severity: Severity

    @Guide(description: "Building and room, or the nearest named landmark.")
    var location: String

    @Guide(description: "Equipment involved, by asset tag if the note gives one.")
    var equipment: [String]

    var followUpRequired: Bool
}

@available(iOS 26.0, macOS 26.0, *)
func extract(from note: String) async throws -> IncidentReport {
    // ✅ The bare initializer is 2026 house style — it appears in Apple's 2026 samples
    //    (corrections register C9n). `SystemLanguageModel.default` remains valid.
    let session = LanguageModelSession {
        "Extract an incident report from the field note."
    }

    // ✅ VERIFIED overload — `respond(to:generating:)`.
    let response = try await session.respond(to: note, generating: IncidentReport.self)
    return response.content
}
```

What changed, and what each change bought:

| Was doing the work | Now doing the work | Effect |
|---|---|---|
| Adapter weights + "return JSON with exactly these keys" | `@Generable struct` | Structural correctness is *guaranteed*, not likely |
| "severity must be one of: minor, moderate, major, critical" | `@Generable enum Severity` | Unrepresentable outputs, and no enum-case drift |
| "Do not wrap in markdown fences" | The type system | Deleted; the constraint cannot be violated |
| `JSONDecoder` + error handling at the call site | `response.content` is already `IncidentReport` | A whole failure class removed |
| ~90 tokens of format prose in every request | ~10 tokens of task description | Context back for the actual note |

### 6.4 ⚠️ The one guide that does not do what it says

There is a runtime-vocabulary version of the enum trick, and it is broken.

> ⚠️ **SILENT FAILURE — `@Guide(.anyOf:)` does not constrain generation.**
>
> ✅ **VERIFIED** — thread 812501. An Apple Designer **reproduced the bug on Apple's end** with this
> exact code, and a Frameworks Engineer confirmed it reproduces on iOS 26.2:
>
> ```swift
> @Generable
> struct Arguments {
>     @Guide(description: "The city to get information about.", .anyOf(["London", "New York", "Paris"]))
>     let city: String
> }
> ```
>
> The model generated **"Beijing"**. Apple's own statement of intent is that `.anyOf` does *both*
> things — lists the options in the schema presented to the model *and* constrains generation at
> prediction time. It simply does not do the second one.
>
> **Why this matters here specifically:** `.anyOf` is the obvious tool for §5.1 reason B, domain
> vocabulary known only at runtime, which is exactly the thing many adapters were trained for. If
> you migrate a vocabulary adapter onto `.anyOf` you will get a *worse* result than the adapter and
> no error telling you so — the value comes back as a plausible, well-formed, out-of-vocabulary
> string.
>
> **What to do instead:**
> 1. **Use a `@Generable enum` when the set is known at compile time.** Enums work; `.anyOf` does
>    not. This is the fix for most cases.
> 2. **Validate at the boundary and fail loudly.** Whatever comes back, check membership yourself.
> 3. Apple's own workaround — restate the constraint in ALL-CAPS instructions — is documented in
>    that thread, and the same thread records the OP's follow-up that the model then got stuck in
>    loops re-calling with invalid arguments. Treat it as a mitigation, not a fix.
>
> Full treatment: [Part 2.2 §4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

A related footgun from the same demo, worth internalising while you are rewriting prompts: if you
constrain a field to a vocabulary and your *prompt* names a value outside it, you have created a
contradiction. Apple's presenter hits this live — asks for Paris, having constrained destinations to
a landmark list that does not contain Paris, and has to change the prompt to "Grand Canyon"
(`notes/transcripts/fm-core.md:1447-1451`). Keep prompt vocabulary and guide vocabulary in sync.

### 6.5 Showing beats telling: one-shot exemplars

For §5.1 reason A — tone and style — the highest-leverage technique is not a longer style
description. It is one good example.

> ✅ **VERIFIED** — `notes/transcripts/fm-core.md`, chapter 3 framing, verbatim:
>
> > "**While a good prompt tells the model what to do, sometimes it's more effective to just show it.
> > We can include a high quality example as an instance of our `@Generable` type directly in a
> > prompt.**"

That is a real capability, not a metaphor: you construct an instance of your `@Generable` type and
put it in the prompt. The exemplar carries register, level of detail, and length in a way that
"write in a concise professional tone" never will — and it costs a few dozen tokens.

```swift prelude:guide-context
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
func extractWithExemplar(from note: String) async throws -> IncidentReport {
    // A hand-authored exemplar in your product's voice. This is the style transfer
    // that the adapter used to do, expressed as data instead of weights.
    let exemplar = IncidentReport(
        summary: "A coolant line on press 4 failed during the night shift.",
        severity: .major,
        location: "Plant 2, press hall",
        equipment: ["PRS-004", "CLN-118"],
        followUpRequired: true
    )

    let session = LanguageModelSession(model: SystemLanguageModel()) {
        """
        Extract an incident report from the field note.
        Match the register and level of detail of the example.
        """
    }

    // 🟡 RECONSTRUCTED assembly — `Prompt { }` is a result builder (`@PromptBuilder`) and
    //    Apple's demo puts a @Generable instance directly into a prompt. The exact
    //    interpolation spelling for an instance is not something we have seen declared.
    //    The safe, always-compiling form is to interpolate the description yourself.
    let prompt = """
        Example of the output style we want:
        \(exemplar)

        Field note:
        \(note)
        """

    return try await session.respond(to: prompt, generating: IncidentReport.self).content
}
```

> 🟡 **RECONSTRUCTED — putting a `@Generable` *instance* into a `Prompt { }` builder.** The
> capability is attested verbatim by Apple's presenter. The exact builder spelling — whether a
> `@Generable` value can be a direct statement inside `Prompt { }` and what it renders as — is not
> something we have a declaration for. **Safe default:** interpolate into a string, as above; it
> works everywhere and the model sees the same content. See
> [Part 2.1 §4.2–4.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md)
> for the builder detail.

### 6.6 For domain vocabulary, retrieve — do not memorise

§5.1 reason B is the case where people most want to keep fine-tuning, and it is the case where
fine-tuning is most often the wrong tool. Facts belong in the prompt, fetched at request time. That
is also Apple's advice for the adjacent problem of context pressure.

> ✅ **VERIFIED** — Apple Technical Note **TN3193**, *"Managing the on-device foundation model's
> context window"*, mitigation 6 of 6: *implement RAG* — fetch relevant snippets dynamically instead
> of passing a whole knowledge base.

Two on-ramps, in increasing order of effort:

1. **Just put it in the prompt.** If your vocabulary is a few hundred terms, a glossary block costs a
   few hundred tokens out of 4,096 and beats an adapter. Measure it with `tokenCount(for:)`
   (**iOS 26.4+**) before you assume it doesn't fit.
2. **Retrieve.** `SpotlightSearchTool` gives you semantic search over content your app has donated —
   and note that `IndexedEntity` content and Core Spotlight items land in the *same* index. See
   [Part 2.4](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md),
   which also carries the known defects: the tool's description and JSON Schema disagree
   (Apple-confirmed known issue, thread 832534), and there is an open asset-catalog error on macOS 27
   betas (thread 838904, Apple: *"Whelp, that's totally a bug"*).

The context budget you are working inside:

> ✅ **VERIFIED** — TN3193 states **4,096 tokens per `LanguageModelSession`** plainly, and an Apple
> Frameworks Engineer gives the same figure in thread 833642, adding that **overflow handling is
> developer-managed, not automatic**. `contextSize` and `tokenCount(for:)` shipped in **iOS 26.4**.
> Read `contextSize` at runtime rather than hardcoding 4096.

That ceiling is the real limit on this path. A glossary that does not fit is a genuine argument for
§8. A glossary that fits is an argument against a quarter of engineering work.

### 6.7 The part you cannot skip: measure it

Everything above is a hypothesis until you have a number. And you need the number *anyway*, because
Apple has told you there is no way to pin the model version.

> ✅ **VERIFIED** — thread 833642, Frameworks Engineer, on model versioning: **no pinning API and no
> version-retrieval API.** The recommended mitigation is to use the **Evaluations framework** to
> catch regressions between OS updates.

So build the suite once and it serves three purposes: it tells you whether Path 1 is good enough, it
becomes your regression net across OS updates, and it is the baseline you would compare §7 or §8
against if you go there.

```swift prelude:guide-context
import Evaluations
import FoundationModels
import Testing

/// Does the no-adapter, guided-generation rewrite hold the line?
/// ✅ VERIFIED shapes — `Evaluation`, `ModelSample`, `ModelSubject<T>`, `Evaluators`,
///    two-argument `Evaluator`, `Metric` + `.passing()`/`.failing()`/`.scoring(_:)`,
///    and `aggregateMetrics(using:)` are all confirmed against Apple's shipping sample
///    code and the `/documentation/evaluations/evaluation` page. See Part 6.1.
struct IncidentExtractionEvaluation: Evaluation {

    let severityMatch = Metric("Severity Match")
    let hasLocation   = Metric("Has Location")
    let summaryLength = Metric("Summary Words")

    // Your adapter-era golden set. These are the cases you already know the answers to
    // because your adapter got them right — that is exactly what makes them useful now.
    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "Coolant line blew on press 4 overnight, whole hall shut.",
                    expected: Severity.major),
        ModelSample(prompt: "Loose guard rail on the mezzanine, taped off, no injury.",
                    expected: Severity.minor),
        // …fifty more. Fifty hand-labelled samples is a day's work and it is the
        //  cheapest insurance in this entire migration.
    ])

    func subject(from sample: ModelSample<Severity>) async throws -> ModelSubject<Severity> {
        let report = try await extract(from: sample.prompt)
        return ModelSubject(value: report.severity)
    }

    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let expected = sample.expected else { return severityMatch.ignore() }
            return subject.value == expected
                ? severityMatch.passing()
                : severityMatch.failing(rationale: "got \(subject.value), expected \(expected)")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: severityMatch)
    }
}
```

Run it against the 26.x adapter build and against the 27 rewrite, and compare. If the delta is
inside your tolerance, you are finished and you can delete §3 from your codebase. If it is not, you
now know *which* samples regressed, which tells you whether you are looking at reason A, B, C or D —
and therefore which of §7 or §8 you are heading for.

[Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) covers the whole ladder, including model-as-judge for the
subjective cases (tone, register) that a `==` comparison cannot score, and the κ-calibration step
that tells you whether to trust the judge.

### 6.8 Where Path 1 genuinely runs out

Be honest about this, because overselling it is how you end up doing the migration twice.

- **A genuinely novel task** (§5.1 reason D). If the base model cannot do the thing at all,
  no instructions block creates the capability.
- **A style you cannot describe or exemplify.** Some style transfer really does need weights.
- **A vocabulary that does not fit in 4,096 tokens** and cannot be retrieved because relevance
  cannot be determined ahead of the model's reasoning.
- **Hard latency or token budgets** where the retrieved context you would need is itself the cost
  you were trying to avoid.
- **Refusals.** If your domain trips guardrails, prompting is not the lever. That is
  [17.3](03-error-taxonomy-migration.md) — and note that
  `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, the documented escape hatch,
  **does not apply to `Generable`**, which is precisely the path this section just put you on.
- **Availability.** The system model is not present for every user — hardware tier, region, Siri
  language, user opt-out, and download state all gate it, and **there is no App Store required-device
  capability for Apple Intelligence** (thread 836810, Frameworks Engineer). If your adapter feature
  was already gated behind availability, Path 1 inherits that gate; §7 and §8 do not.

Any of those, and you are in §7 or §8. All of them together, and you were always going to be.

### 6.9 A token budget you can actually check

Path 1 trades weights for context. That trade has a hard ceiling, and the single most common way
this rewrite fails is that somebody estimates the glossary at "a few hundred tokens," ships it, and
discovers in the field that the combination of instructions, schema, retrieved context and a long
user input overflows.

You do not have to estimate. Since **iOS 26.4** you can measure.

> ✅ **VERIFIED** — TN3193 confirms `tokenCount(for:)` covers **instructions, prompts, tools, schemas
> and transcript entries**, and that `contextSize` and `tokenCount(for:)` both arrived in **iOS 26.4**.
> A DTS Engineer announced `tokenCount(for:)` in thread 817502: *"since iOS 26.4 (and friends), we
> have the following API that returns the token count for the specified instructions."*
>
> ✅ **SDK-verified 2026-07-29:** `SystemLanguageModel` has five asynchronous overloads,
> `tokenCount(for:)` for a `PromptRepresentable`, `Instructions`, `[any Tool]`,
> `GenerationSchema`, and a collection of `Transcript.Entry`. The example below uses the
> `Instructions` overload for the instruction prefix and the prompt overload for the two inputs.

```swift compile:27
import FoundationModels

/// Fail loudly at development time rather than quietly in production.
/// `contextSize` and `tokenCount(for:)` are iOS/macOS 26.4+.
@available(iOS 26.4, macOS 26.4, *)
func auditBudget(instructions: String, glossary: String, sampleNote: String) async throws {
    let model = SystemLanguageModel()

    // Read the ceiling. Do NOT hardcode 4096 — Apple's own guidance is to read it
    // at runtime, and it is not guaranteed to be constant across devices or releases.
    let ceiling = model.contextSize

    let instructionTokens = try await model.tokenCount(for: Instructions { instructions })
    let glossaryTokens    = try await model.tokenCount(for: glossary)
    let noteTokens        = try await model.tokenCount(for: sampleNote)

    // Leave room for the response. Whatever you reserve, reserve it explicitly.
    let reservedForOutput = 512
    let used = instructionTokens + glossaryTokens + noteTokens + reservedForOutput

    print("""
        context ceiling ....... \(ceiling)
        instructions .......... \(instructionTokens)
        glossary .............. \(glossaryTokens)
        sample input .......... \(noteTokens)
        reserved for output ... \(reservedForOutput)
        headroom .............. \(ceiling - used)
        """)

    precondition(used < ceiling, "Path 1 budget blown by \(used - ceiling) tokens")
}
```

Run that over your *longest* realistic input, not a typical one. The schema costs tokens too — which
is the argument for Apple's fourth TN3193 mitigation.

> ✅ **VERIFIED** — TN3193's six recommended mitigations, which are also the right checklist for
> shrinking a Path 1 prompt:
>
> 1. **Split tasks across multiple sessions** — smaller steps, a new session each, combine results.
> 2. **Request less content** — put the target length in the prompt ("In 3 sentences…") and use
>    `Guide(description:)` with `maximumCount(_:)`.
> 3. **Reduce prompt size** — concise language, one to three paragraphs maximum.
> 4. **Use `Generable` types efficiently** — minimise type complexity, use short property names,
>    apply `@Guide` sparingly. **Every guide costs context.**
> 5. **Optimise tool calling** — brief descriptions, **limit to 3–5 tools**, and consider running
>    tools *before* calling the model.
> 6. **Implement RAG** — fetch relevant snippets dynamically instead of passing a whole knowledge base.

Mitigation 4 is worth dwelling on, because it cuts against the instinct this section has been
encouraging. `@Generable` earns its place by removing *prose* about structure. But every
`@Guide(description:)` you attach is prose you just added back. In the §6.3 example, three of the
five fields carry a guide; if the budget is tight, the two least ambiguous guides come off first and
you check whether accuracy moved. That is a measurement, not a preference — §6.7 is how you make it.

Mitigation 1 is the escape hatch when the budget genuinely will not close: two sessions, each with a
narrower job and a smaller schema, beat one session carrying everything. If your adapter was doing
two things at once — say, normalising vocabulary *and* extracting structure — splitting it into two
sessions is often the whole migration.

### 6.10 What Apple's 2026 samples actually do, which is not what the 2025 ones did

One migration-relevant behaviour change worth knowing, because it will make you rewrite code you
were about to carefully port:

> ✅ **VERIFIED** — from the corrections drawn out of Apple's 2026 sample projects (Origami, Book
> Tracker, and the hiking-trails Spotlight sample; corrections register C9, item p): **the 2026
> samples dropped proactive `availability` gating** in favour of reactively catching
> `SystemLanguageModel.Error`. The stale iOS 26 sample still gates proactively.

Both remain valid. The distinction matters for you specifically because adapter-era code almost
always gated proactively — you had to, since you needed to know whether to fetch an asset pack —
and that habit produces a lot of ceremony you no longer need on the plain system-model path.

Two further sample-derived facts that will save you time in a Path 1 rewrite:

- **`SystemLanguageModel.Error` is checked *first*** in the error chain, ahead of
  `LanguageModelError`, and `GeneratedContent.ParsingError` is a separate thing again. The full
  ordering is [17.3](03-error-taxonomy-migration.md)'s job; the point here is that a `catch` list
  you inherit from 26.x is probably in the wrong order.
- ⚠️ **A stream can finish having yielded zero partials** when the model emits only a tool call
  (`CoachModel.swift:67-72` in Apple's sample). Any "spinner until first token" UI hangs forever.
  If your adapter feature streamed, check this before you ship the rewrite —
  [Part 2.2 §9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md).

---

## 7. Path 2 — Core AI and `CoreAILanguageModel`

This is the path Apple named. The Frameworks Engineer's sentence — *"provide your own custom models
using Core ML or Core AI"* — points here, and for a language model, Core AI rather than Core ML is
the relevant half.

The good news first: **your session code does not change.** `LanguageModelSession` is now built on a
public `LanguageModel` / `LanguageModelExecutor` protocol pair, and `CoreAILanguageModel` is a
conformer. Everything downstream of the session — prompts, tools, streaming, transcripts, Dynamic
Profiles — keeps working.

The bad news is everything else. You are not swapping a model; you are taking ownership of a
supply chain.

### 7.1 The one line, and what it hides

> ✅ **VERIFIED** — Apple's own doc comment in
> `apple/coreai-models`, `swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift:23-31`,
> reproduced in the README of every model in that repository:

```swift prelude:external-module
import FoundationModels
import CoreAILanguageModels

let model = try await CoreAILanguageModel(resourcesAt: modelURL)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "What is quantum computing?")
print(response)
```

Two lines of difference from a `SystemLanguageModel` session. That is genuinely the API surface.

The type, ✅ verified from the same file:

```swift illustrative
public struct CoreAILanguageModel: LanguageModel {
    public enum LoadMode: Sendable { case lazy; case eager }
    public typealias Executor = CoreAIExecutor

    public init(resourcesAt url: URL,
                mode: LoadMode = .lazy,
                variant: String? = nil,          // e.g. "coreai-sequential", "ane"
                kvCacheStrategy: KVCacheStrategy = .auto) async throws

    public var capabilities: LanguageModelCapabilities   // .toolCalling / .reasoning / .guidedGeneration
    public var executorConfiguration: CoreAIExecutor.Configuration
    public var estimatedSizeOnDiskBytes: Int? { get }
    public func load() async throws
    public func unload()
}
```

Note `mode: .lazy` is the default — construction does not load the engine. `load()` is optional
because `respond` auto-loads. `estimatedSizeOnDiskBytes` is there because you are now the one who
has to care about that number.

Packaging note that costs people an afternoon: the SPM **product** is `CoreAILM`, the **module** is
`CoreAILanguageModels`, and the package is `apple/coreai-models`. Module name ≠ product name, so
your `Package.swift` says one and your `import` says the other (✅ verified against a third-party
integration's `Package.swift`, `notes/repos/swift-lm.md:57-62,106`). Separately, `CoreAI` — the
framework the runtime actually sits on — is an **OS framework in the 27 SDK**, not a package.

### 7.2 ⚠️ The constraint that decides this for many readers: `@Generable` and logits

If your adapter existed for §5.1 reason C — structured-output reliability — read this before you
plan anything.

> ⚠️ **SILENT FAILURE — the fastest Core AI engine cannot do guided generation, and the fact is
> discovered at runtime, not at build time.**
>
> Grammar-constrained decoding needs the model's **logits** at every step so it can mask the tokens
> the grammar forbids. The GPU-pipelined Core AI engine samples **on the GPU**, and never returns
> logits to the CPU at all. So the fastest execution path is structurally incapable of the feature
> Apple markets hardest.
>
> ✅ **VERIFIED in Apple's own source** — `apple/coreai-models`:
>
> - Capability detection at model init: `isGuidedGenerationSupported` = the loaded engine's
>   `supportsLogits` **if known**, otherwise `variant != "coreai-pipelined"`
>   (`CoreAILanguageModel.swift`, recorded at `notes/repos/apple-coreai-models.md:860`).
> - `CoreAIPipelinedEngine` — the GPU, on-device-sampling engine — has **`supportsLogits == false`**
>   (`notes/repos/apple-coreai-models.md:1139`), and when asked for logits raises, verbatim:
>
>   > `"CoreAI pipelined engine does not support logits (GPU-side sampling). Use a sequential engine
>   > for constrained generation or evaluation."`
>
> - The error that reaches your `catch` is:
>
>   ```swift
>   LanguageModelError.unsupportedCapability(
>       .init(capability: .guidedGeneration, debugDescription: "…"))
>   ```
>
> **Why it is silent in the way that matters:** the failure is not "my model is bad," it is
> "`respond(to:generating:)` throws on the exact bundle variant I chose for speed." It compiles. It
> passes any test that only exercises plain-text generation. Then it throws in production on the one
> code path that produces your structured output — and only on the devices or configurations that
> selected the pipelined variant.
>
> **What to do:** decide, explicitly and in writing, which you need. If you need `@Generable`, select
> a sequential (or static-shape) variant and accept the throughput. If you need the pipelined
> engine's speed, your structured output has to come from parsing, with validation and a retry, and
> you should build that before you find out you need it. Check `model.capabilities` after `load()`
> and branch, rather than discovering it from a thrown error.
>
> Full treatment in
> [Part 7.4 (bundles, engines and guided decoding)](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md)
> and [Part 4.2 §5](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md).

Defensive shape, since you cannot rely on a compiler error:

```swift prelude:external-module
import FoundationModels
import CoreAILanguageModels

@available(iOS 27.0, macOS 27.0, *)
func makeSession(at url: URL) async throws -> (LanguageModelSession, Bool) {
    let model = try await CoreAILanguageModel(resourcesAt: url)
    try await model.load()                     // capabilities are engine-derived; load first

    // ✅ `capabilities` is a public property of `CoreAILanguageModel`, and
    //    `.guidedGeneration` is one of the three cases Apple's source names.
    let canGuide = model.capabilities.contains(.guidedGeneration)

    if !canGuide {
        // Log it loudly at startup. Do NOT let this surface as a first-user-request error.
        print("[core-ai] guided generation unavailable for this bundle variant — using text + parse")
    }
    return (LanguageModelSession(model: model), canGuide)
}
```

### 7.3 The other things the Foundation Models path does not carry across

Smaller than §7.2, but they will surprise you if your adapter-era tuning relied on them.

> ✅ **VERIFIED** — from `CoreAILanguageModel.swift` as recorded at
> `notes/repos/apple-coreai-models.md:907-908`:
>
> - **Only `temperature` is honoured** through the Foundation Models path. `makeSamplingConfig`
>   returns a `SamplingConfiguration(temperature:)` when set, and otherwise the model's base config,
>   which is `.greedy`. **`topK`, `topP` and `minP` are not reachable** through `GenerationOptions`
>   on this path, even though the underlying sampler implements them.
> - **Default `maxTokens`** is `request.generationOptions.maximumResponseTokens ?? (model.supportsReasoning ? 2048 : 512)`.
>   If your outputs are getting cut off at what looks like an arbitrary length, that is the 512.
> - **Reasoning entries are skipped when re-templating the transcript** — Apple's source comment:
>   *"Don't echo the model's prior reasoning back into the prompt."*

Capabilities are **detected, not declared**: `supportsReasoning` is true if the tokenizer has
`<think>` or `<|reasoning_start|>`; `supportsToolCalling` is true if tool-call markers are detected
in the tokenizer. So a model that "should" support tool calling but uses non-standard markers will
quietly not, and the detection list is a small fixed set (`<tool_call>`, `<function_calls>`, plus a
Mistral special case). ✅ verified, `notes/repos/apple-coreai-models.md:857-869`.

### 7.4 The bill

This is the part the one-line API hides. Each row is a thing the platform used to do for you and now
does not.

| You now own | What it means | Where it is covered |
|---|---|---|
| **Conversion** | PyTorch checkpoint → `.aimodel`, with op-coverage failures, and `.aimodel` is a **directory**, not a file | [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) |
| **Compression** | Quantisation and palettization decisions you previously did not make | [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) |
| **Size** | Hundreds of MB to multiple GB in your app or asset packs. `estimatedSizeOnDiskBytes` exists for a reason | [Part 15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| **Specialization latency** | `.aimodel` is portable *source*. It must be compiled for this device **and this OS version** before it runs — Apple: *"It is recommended you avoid having model specialization occur within user interactive flows."* Community-measured **194 s** for a 3 GB model's first load on an iPhone | [Part 7.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md) |
| **Re-specialization on OS update** | The cache key includes the OS. An OS update can invalidate everything, at which point a returning user pays the first-load cost again | [Part 7.2 §6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md), [17.6](06-toolchain-and-asset-compatibility.md) |
| **Distribution and updates** | Background Assets or your own transport, plus versioning, rollback and integrity | [Part 15.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md) |
| **Memory** | Unlike `SystemLanguageModel`, which is **not loaded into your app's memory**, your model is. This matters enormously in extensions | thread 833575 (DTS Engineer) |
| **Evaluation** | Nobody else is testing your model | [Part 6](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md) |

That memory row deserves its own emphasis, because it is the one people get wrong in extensions:

> ✅ **VERIFIED** — thread 833575, DTS Engineer (Ziqiao Chen), marked Recommended:
>
> > "The system language model (`SystemLanguageModel`) is **not loaded into the app / extension's
> > memory**, and so using it **doesn't count on the memory limit of your extension**. If you are
> > using your own on-device model, the model will be loaded to the memory of your app / extension,
> > and so you will need to test if that is fine for your extension. Note that some extensions don't
> > allow XPC due to privacy reason, and hence can't use a model via the Foundation Models
> > framework."

If your adapter feature lived in a widget, a share extension or a keyboard, this row may end the
Core AI conversation on its own.

### 7.5 Delivery: what carries over from §3, and what does not

Apple's sentence ends with *"Background Assets remains a great way to deliver custom models to your
users."* That is the same delivery framework the adapter pipeline used, which is genuinely good news
— the concepts transfer.

What does **not** transfer:

- **The `com.apple.developer.foundation-model-adapter` entitlement.** It is adapter-specific. Remove
  it.
- **`xcrun ba-package foundation-models package`.** That subcommand exists to package `.fmadapter`
  bundles. There is no evidence it packages `.aimodel` directories, and every reason to think it
  does not.
- **`SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name:)`.** There is no Core AI
  equivalent, because there is no base model your asset has to match. Your model *is* the model.
  This is one of the few places the migration makes life simpler.

What carries over as *pattern* rather than as code: the §4.3 rule. Resolve, ensure availability,
*then* construct. Give download failures their own error case.

> 🔴 **GAP — the 2026 Background Assets API for Core AI is undocumented.** There is **no Apple sample,
> no WWDC26 transcript and no documentation page** in our corpus showing Background Assets delivering
> an `.aimodel` or `.aimodelc`. The verified fragments we have (`ensureLocalAvailability(of:requireLatestVersion:)`,
> `AssetPackManager.shared.statusUpdates(forAssetPackWithID:)`, the three `BA*` plist keys) all come
> from the **adapter era**, quoted in §3. **What would resolve it:** the WWDC25 "Discover
> Apple-Hosted Background Assets" session transcript, the current `backgroundassets` reference, or
> any first-party sample. **Safe default:** define your own narrow `ModelDelivery` protocol, implement
> it first with plain `URLSession` background downloads, and swap Background Assets in behind it. That
> is the approach [Part 15.1 §3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
> works through in full, and it costs about forty lines.

### 7.6 One structural fact worth knowing before you convert

If you are converting a model anyway, this changes how you convert it.

> ✅ **VERIFIED — with a scope correction** (Apple's shipping source, `apple/coreai-models`,
> `ModelStructure.swift:71-80`, recorded in the corrections register as C6): the optional
> `coreai-models` loader recognizes a multi-entry-point structure and **selects a Neural Engine
> preference for models that have one — a package loading policy, not a Core AI framework routing
> contract.**[^sample-routing-policy] Direct `AIModel` callers choose their own
> `SpecializationOptions`, and Core AI's documented `.default` picks the compute-unit combination
> that minimizes latency. WWDC26 session 325 presents the split of SAM3 into `image_encode` /
> `text_encode` / `detect` as a *latency* trick — run each at a different cadence, 76% faster
> second inference — and reading the code shows the split is additionally what the package's
> classifier keys its ANE preference on ([Part 7.2 §11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)
> and [Part 10.1 §8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-10-coreai-hardware-authoring-debugging/references/01-ane-vs-gpu-authoring-rules.md)
> work through the classifier).
>
> ⚠️ With a caveat that bites: `CoreAISegmentationEngine` **re-runs `image_encode` on every call**
> and exposes no cache. The 76% figure requires caller-side work that Apple's own package does not
> do for you.

For a language model this matters less directly than for the vision case, but the principle — that
model *structure* can steer how Apple's convenience wrappers place a model, while the wrappers do
not always exploit what the structure enables — is the right expectation to carry into Parts 8
and 10.

### 7.7 When Core AI is the right answer

- You already have a converted `.aimodel`, or a checkpoint someone else has converted.
- You need the Neural Engine — for battery, for thermals, or because the GPU is busy with your app.
- You want the path Apple named, and the ability to say so to a security review.
- Your structured output can survive §7.2, either because you are taking a sequential variant or
  because you are parsing.
- Your model fits in your app's memory budget, including in whatever extension needs it.

### 7.8 When it is not

- You still need to *train*. Core AI has no Apple-published on-device or on-Mac fine-tuning story
  that we can verify; it is an inference framework. If §5.1 reason D is why you are here and you
  do not have a trained checkpoint, go to §8.
- You need `@Generable` **and** maximum throughput. Pick one, or reconsider §6.
- You are relying on sampling controls beyond temperature (§7.3).
- You need first-party sample code to learn from. **`coreai` has zero sample-code projects** —
  verified this cycle, 0 `sampleCode` entries across all 312 indexed Core AI symbols. The strongest
  available references are Apple's own repositories and this series' Part 7.

### 7.9 The migration skeleton

Because there is no Apple sample, here is the shape the port takes — assembled from the verified
pieces above and marked where it is assembling rather than quoting. It exists so you can see all the
new responsibilities in one screen, not as something to paste.

```swift prelude:external-module
import Foundation
import FoundationModels
import CoreAILanguageModels

/// Everything the adapter path used to get for free, made explicit.
@available(iOS 27.0, macOS 27.0, *)
actor OnDeviceModelHost {

    // The failures are DIFFERENT KINDS OF FAILURE and must stay separable.
    // This is §4.2's lesson carried forward: a delivery problem must never
    // reach your telemetry wearing a model problem's name.
    enum HostError: Error {
        case assetUnavailable(underlying: Error)     // it isn't on disk
        case modelLoadFailed(underlying: Error)      // it's on disk and won't load
        case guidedGenerationUnavailable             // §7.2 — engine has no logits
    }

    private var model: CoreAILanguageModel?
    private var supportsGuidedGeneration = false

    /// Your own delivery abstraction. Implement with URLSession first; swap in
    /// Background Assets behind it later. See Part 15.1 §3.2 for why this
    /// indirection is the safe default while the BA-for-Core-AI gap is open.
    private let delivery: ModelDelivery

    init(delivery: ModelDelivery) { self.delivery = delivery }

    // ── Step 1: the asset. Availability BEFORE construction, always. ──────────
    func prepare(progress: @Sendable (Double) -> Void) async throws -> URL {
        do {
            return try await delivery.ensureAvailable(progress: progress)
        } catch {
            throw HostError.assetUnavailable(underlying: error)
        }
    }

    // ── Step 2: specialization. This is the expensive one. ────────────────────
    //
    // A `.aimodel` is portable SOURCE. It must be specialized for this device
    // and this OS version before it runs, and Apple's own guidance is to keep
    // that out of interactive flows. Community-measured: 194 s for a 3 GB model
    // on first load. Part 7.2 covers `AIModelCache.default.model(for:options:)`,
    // which returns nil without specializing — the gating primitive for a
    // "Preparing…" screen.
    func loadModel(at url: URL) async throws {
        do {
            // `.eager` because we have already decided this is a non-interactive
            // moment. `.lazy` (the default) defers the engine load to first respond.
            let m = try await CoreAILanguageModel(resourcesAt: url, mode: .eager)
            self.model = m
            // Capabilities are DETECTED from the loaded engine and the tokenizer,
            // not declared. Read them after loading. §7.2, §7.3.
            self.supportsGuidedGeneration = m.capabilities.contains(.guidedGeneration)
        } catch {
            throw HostError.modelLoadFailed(underlying: error)
        }
    }

    // ── Step 3: a session. From here down, nothing has changed since 26.x. ────
    func makeSession(instructions: String) throws -> LanguageModelSession {
        guard let model else { throw HostError.modelLoadFailed(underlying: CocoaError(.fileNoSuchFile)) }
        return LanguageModelSession(model: model) { instructions }
    }

    // ── Step 4: structured output, or an honest refusal to promise it. ────────
    func extract(from note: String, instructions: String) async throws -> IncidentReport {
        guard supportsGuidedGeneration else {
            // Fail here, at a boundary you control, with an error that names the
            // real cause — rather than letting `unsupportedCapability` surface
            // from inside a stream on a user's first request.
            throw HostError.guidedGenerationUnavailable
        }
        let session = try makeSession(instructions: instructions)
        return try await session.respond(to: note, generating: IncidentReport.self).content
    }

    // ── Step 5: memory. Your model is in YOUR process now. ────────────────────
    func releaseModel() {
        model?.unload()
        model = nil
        supportsGuidedGeneration = false
    }

    var estimatedDiskBytes: Int? { model?.estimatedSizeOnDiskBytes }
}

/// The forty lines that keep you out of the Background Assets gap (§7.5).
protocol ModelDelivery: Sendable {
    func ensureAvailable(progress: @Sendable (Double) -> Void) async throws -> URL
}
```

> 🟡 **RECONSTRUCTED — the assembly, not the parts.** Every API named above is ✅ verified
> individually (§7.1–§7.3). The *composition* — this actor, this error enum, this ordering — is this
> guide's construction, because Apple ships no sample that shows one. Marked honestly, per §9.

Read that skeleton against §3.6's `LegacyAdapterLoader` and the migration's real shape becomes
visible. The two are structurally the same program: resolve an asset, ensure it is local, construct
something, use it. What grew is what is *inside* step 2 — where the adapter path had a download and
a hash lookup, the Core AI path has a multi-second-to-multi-minute compile whose cost depends on the
device and the OS version, which can be invalidated by an OS update, and which you must schedule
somewhere other than in front of a waiting user.

That, more than the API surface, is what "you now own the supply chain" means in practice.

---

## 8. Path 3 — MLX and `MLXFoundationModels`

This is the path Apple did not name in the adapter thread, and it is the only one where you can
still do the thing the adapter did: **fit weights to your data**.

`mlx-lm` ships a documented, maintained LoRA/DoRA/full fine-tuning CLI. It runs on your Mac. It
takes a Hugging Face checkpoint and your JSONL and produces adapter weights. And `mlx-swift-lm`
ships `MLXFoundationModels`, whose `MLXLanguageModel` conforms to the same `LanguageModel` protocol
as everything else — so, exactly as with Core AI, your `LanguageModelSession` code is unchanged.

If your adapter was §5.1 reason D — a genuinely different task — this is where you are going.

### 8.1 Apple does point here, in a different conversation

Not in the adapter thread. But asked how to reach users whose devices cannot run Apple's on-device
model, an Apple Designer answers:

> ✅ **VERIFIED** — thread 836810, Apple Designer (Apple):
>
> > "Models from other sources can be used with Foundation Models using **MLX or CoreAI**, so you can
> > still reach users with hardware that can't run Apple's on-device foundation model."

That is an endorsement of MLX as a first-class `LanguageModel` backend. It is *not* an endorsement of
MLX as the adapter replacement — nobody at Apple has said that — and this guide is not going to
pretend otherwise. What it is: the only route in the 2026 stack where on-device adaptation is still
a supported, shipping workflow.

### 8.2 Where `MLXFoundationModels` actually is

This confused enough developers to generate a forum thread.

> ✅ **VERIFIED** — thread 836264, *"Bring an LLM provider to the Foundation Models, missing MLX
> dependencies"* (2026-06-27). The OP asks: *"Where is this framework, there are no BETA branches on
> the MLX framework either."* Apple's reply:
>
> > "This is being introduced to `mlx-swift-lm` in **PR#334**
> > (see here: https://github.com/ml-explore/mlx-swift-lm/pull/334)."

So: it is a **library inside `ml-explore/mlx-swift-lm`**, not a separate framework, not an Apple SDK
framework, and not something you will find by searching Apple's documentation.

Full setup — package traits, the double gate, and the two construction paths — is
[Part 13.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md). The
migration-relevant summary:

> ⚠️ **The double gate, and the empty library.** ✅ VERIFIED from `mlx-swift-lm`'s own
> `Package.swift` comments and CI notes (`notes/repos/mlx-swift-lm.md:78-89, 2362, 2625`):
> `MLXFoundationModels` is compiled only when **both** the `FoundationModelsIntegration` package
> trait is enabled (default-on) **and** `canImport(FoundationModels, _version: 2)` succeeds — which
> is true on the **macOS/iOS 27 SDK only**.
>
> On a 26 SDK it compiles to an **empty library**. Not an error. An empty library. Your `import
> MLXFoundationModels` succeeds and `MLXLanguageModel` does not exist, so you get an
> unresolved-symbol error pointing at your own code rather than at the gate. `mlx-swift-lm`'s own
> nightly CI hit exactly this on an Xcode 26.5 runner. This is the same silent-failure genre as
> everything else in this guide, and [17.4](04-dual-sdk-builds.md) is the guide for it.

### 8.3 The fine-tuning workflow, end to end

This is a Mac-side pipeline. Nothing here runs on the device — see §11 for why that distinction
matters.

> ✅ **VERIFIED** — all commands and flags below are read from `mlx-lm`'s shipped source and its
> `LORA.md`, recorded at `notes/repos/mlx-lm.md:1240-1290, 1400-1440`. Where `LORA.md` and the actual
> argument parser disagree, this guide follows the parser and says so.

```bash
# 0. Install with the training extra. Without [train], mlx_lm.lora will not import.
pip install "mlx-lm[train]"

# 1. Optional: quantize the base model first. If --model points at a quantized model,
#    training automatically becomes QLoRA. mlx-lm's own words:
#    "If --model points to a quantized model, then the training will use QLoRA,
#     otherwise it will use regular LoRA."
mlx_lm.convert --model Qwen/Qwen3-0.6b -q

# 2. Train. This is the step that replaces the Adapter Training Toolkit.
mlx_lm.lora \
  --model ./qwen3-0.6b-4bit \
  --train \
  --data ./data \
  --iters 600 \
  --fine-tune-type lora \
  --num-layers 16 \
  --batch-size 4

# 3. Test-set perplexity against held-out data.
mlx_lm.lora --model ./qwen3-0.6b-4bit --adapter-path ./adapters --data ./data --test

# 4. Sanity-check generation with the adapter applied, before you fuse anything.
mlx_lm.generate --model ./qwen3-0.6b-4bit --adapter-path ./adapters --prompt "..."

# 5. Fuse the adapter into the weights, producing a standalone model.
mlx_lm.fuse --model ./qwen3-0.6b-4bit --adapter-path ./adapters --save-path ./fused_model
```

`--fine-tune-type` takes **`lora`**, **`dora`** or **`full`**. Training writes
`adapters.safetensors` plus periodic `{iteration:07d}_adapters.safetensors` checkpoints into
`--adapter-path` (default `adapters`), along with an `adapter_config.json` recording
`num_layers`, `lora_parameters` and `fine_tune_type` — which is what `load_adapters` reads back to
rebuild the layer structure.

**Data formats** — auto-detected from the first record of `train.jsonl` (detection order:
prompt+completion → chat → text):

```jsonl
{"messages": [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}
{"messages": [...], "tools": [{"type":"function","function":{...}}]}
{"prompt": "What is the capital of France?", "completion": "Paris."}
{"text": "This is an example for the model."}
```

Local training expects `train.jsonl` and optionally `valid.jsonl` / `test.jsonl` inside `--data`.
Note that `--mask-prompt` (compute loss on the completion only — usually what you want for an
extraction or classification task) is **not supported for `text` datasets**.

**Memory levers**, from `LORA.md`: use QLoRA, `--batch-size 1`, `--grad-accumulation-steps N`,
`--num-layers 4`, shorter sequences, `--grad-checkpoint`.

> **Attribution — one number, and it is not ours.** `mlx-lm`'s `LORA.md` states: *"The above command
> on an M1 Max with 32 GB runs at about 250 tokens-per-second."* That is a **project-documentation
> figure** for one specific command on one specific machine, not an Apple figure and not measured by
> us. Do not extrapolate it to your model, your data or your hardware. Measure your own.

Three gotchas that will cost you time, all ✅ verified against source:

1. **`mlx_lm.fuse --hf-path` does not exist** in the current version, despite `LORA.md` documenting
   it. The real flags are `--model`, `--save-path`, `--adapter-path`, `--upload-repo`, `--dequantize`,
   `--export-gguf`, `--gguf-path`, `--trust-remote-code`.
2. **DoRA dequantizes the base weight on every forward pass**, which makes it substantially slower
   and heavier than LoRA on quantized models. `DoRAEmbedding.from_base` raises outright for quantized
   embeddings. Reach for DoRA deliberately, not by default.
3. **Adapters are rejected in distributed mode** — `mlx_lm.server` and the distributed paths error
   with *"Adapters not supported in distributed mode."* If you plan to serve a fine-tune across
   machines, fuse first.

Full treatment in
[Part 12.6 (fine-tuning and porting models)](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/06-finetuning-and-porting-models.md).

### 8.4 Fuse, don't ship an adapter — and why

You have two ways to get the fine-tune onto the device:

**Fuse (recommended).** `mlx_lm.fuse` folds the low-rank delta into the base weights and writes a
standalone model directory. You ship one artifact. There is no runtime adapter step, no
configuration mismatch to get wrong, and no second failure mode at load time. The mechanics, for the
curious: `LoRALinear.fuse()` computes
`delta = ((scale * lora_b.T) @ lora_a.T).astype(weight.dtype)` and adds it to the base weight
(✅ verified, `notes/repos/mlx-lm.md:1314-1316`).

**Load at runtime.** `mlx-swift-lm` does support this — there is a real Swift adapter API:

```swift prelude:guide-context
// ✅ VERIFIED — Libraries/MLXLMCommon/Adapters/ModelAdapter.swift and LoRA/LoRAContainer.swift
public protocol ModelAdapter: Sendable {
    func load(into model: LanguageModel) throws
    func fuse(with model: LanguageModel) throws
    func unload(from model: LanguageModel)
}

public struct LoRAContainer: ModelAdapter, @unchecked Sendable {
    public let configuration: LoRAConfiguration
    public static func from(directory: URL) throws -> LoRAContainer   // adapter_config.json + adapters.safetensors
    public func load(into model: LanguageModel) throws
    public func fuse(with model: LanguageModel) throws
    public func unload(from model: LanguageModel)
}
```

⚠️ **Note the name collision.** `LanguageModel` in that protocol is **MLX's** `LanguageModel`, not
Foundation Models' `LanguageModel`. Two protocols, one name, both in scope in a file that imports
both. This is a genuine source of confusing compiler errors and is worth a `typealias` at the top of
any file that touches both worlds.

Ship fused unless you have a specific reason not to — the honest one being that you want to A/B two
adaptations against one downloaded base model, which halves your download. If you do, you now own a
compatibility contract between adapter and base that looks uncomfortably like the one §3.3 describes
as the reason adapters ended.

### 8.5 Driving it from `LanguageModelSession`

> ✅ **VERIFIED** — from the doc comment on `MLXLanguageModel`
> (`Libraries/MLXFoundationModels/MLXLanguageModel.swift:304-337`):

```swift illustrative
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import HuggingFace
import Tokenizers
import FoundationModels

let model = MLXLanguageModel(
    configuration: ModelConfiguration(id: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
    capabilities: [.guidedGeneration, .toolCalling],
    weightsLocation: { id in … },
    load: { configuration, progressHandler in
        try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: progressHandler)
    })

let session = LanguageModelSession(model: model, tools: [], instructions: nil)
let response = try await session.respond(to: "Hello!")
print(response.content)
```

> **Reality check.** WWDC26 session 339 narrates this as *"if you want to try the latest open source
> models, simply pass in a model ID, and let the framework handle the rest."* The shipping
> initializer is `init(configuration:capabilities:configurationResolver:weightsLocation:load:)` — the
> ID alone is not enough; you inject a downloader and a loader. The `#hubDownloader()` and
> `#huggingFaceTokenizerLoader()` macros are what make the narration roughly true in practice. There
> is also a `#huggingFaceLanguageModel(configuration:capabilities:configurationResolver:)` macro,
> ✅ annotated `@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)`.

For your fine-tune you point `configuration`/`weightsLocation` at your fused model rather than at a
`mlx-community` id. [Part 13.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) and
[13.3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) walk both
construction paths in full.

**Guided generation works here.** `MLXGuidedGeneration` is a real, trait-gated library in the same
package, and `capabilities: [.guidedGeneration, ...]` is a real declaration. Note the word
*declaration*: on this path capabilities are something you **assert**, not something the framework
detects for you — which is the opposite of Core AI's behaviour (§7.3) and means an incorrect
`capabilities` array is a promise your model will fail to keep at runtime.

### 8.6 The bill

| You now own | Detail |
|---|---|
| **A hard 27.0 floor, doubled** | `MLXFoundationModels` needs the 27 SDK **and** the package trait. On 26 it is an empty library, silently (§8.2) |
| **App size** | You are shipping weights. A 3B model at 4-bit is on the order of GBs before you have written a feature |
| **Memory, explicitly** | `MLXLanguageModel` keeps a **process-global `static let cache = ModelCache()`** outside the executor, and exposes `evict()` / `evictAll()` because the automatic teardown does not apply. Apple's own doc comment: *"Without caching, model loading takes 2-30 seconds per request."* You are managing that trade-off by hand |
| **No Neural Engine** | See below |
| **Training infrastructure** | Data curation, a training machine, checkpoints, and a decision about when to retrain |
| **Model updates** | Every base-model bump is a re-fine-tune and a re-fuse and a re-ship |

> 🟡 **RECONSTRUCTED — "no ANE".** MLX executes on the **GPU via Metal**, and on the CPU. Nothing in
> our MLX corpus — the mlx-lm source notes, the mlx-swift-lm source notes, the MLX documentation-site
> crawl, or the TensorOps/Metal Performance Primitives header analysis — describes a Neural Engine
> backend, and MLX's own kernel-level work (hand-dequantisation into threadgroup memory, cooperative
> tensors, `MLX_ENABLE_TF32`) is entirely Metal-shaped. Do not confuse the **M5 GPU's neural
> accelerators** — which MLX does target, inferred from `get_architecture_gen() >= 17` — with the
> Apple Neural Engine; they are different hardware. **What would resolve it:** an explicit statement
> from the MLX maintainers or an ANE backend in the source tree. **Safe default:** plan for GPU
> execution, and budget for its power and thermal profile. If ANE residency is a requirement, §7.

### 8.7 When MLX is the right answer

- **You need to keep training.** This is the decisive one. Nothing else in the 2026 stack lets you.
- Your adaptation is genuinely structural (§5.1 reason D), and §6 measurably fails.
- You are already running MLX for something else, so the size and memory cost is amortised.
- You want to iterate fast: the `convert → lora → generate → fuse` loop is minutes, not a release
  cycle.

### 8.8 When it is not

- You need the Neural Engine, or a battery/thermal profile that implies it.
- You need to support iOS 26 in the same binary without conditional compilation gymnastics
  ([17.4](04-dual-sdk-builds.md) is the guide, and it is real work).
- Your app cannot afford the download or the memory.
- You do not have training data. An adapter you trained in 2025 implies you *did*; make sure it
  still exists, is still licensed for this use, and is still representative. Retraining on stale data
  reproduces a 2025 product, not a 2026 one.

### 8.9 Translating your adapter's hyperparameters

If you have an Adapter Training Toolkit configuration, you may be wondering what carries over. The
honest answer is: **the concepts, not the numbers.**

> 🔴 **GAP — there is no published mapping from Foundation Models adapter hyperparameters to
> `mlx-lm` ones.** We have never seen the Adapter Training Toolkit's configuration schema, so this
> guide cannot tell you that your rank 16 becomes `--fine-tune-type lora` with
> `lora_parameters.rank = 16`. It is probably close to that, and "probably" is not good enough to
> print as a table. **What would resolve it:** the toolkit's config documentation, which is frozen
> at 26.0.0 and may or may not still be published. **Safe default:** treat the MLX fine-tune as a
> fresh hyperparameter search, starting from `mlx-lm`'s defaults, and use your evaluation suite
> (§6.7) to find the setting rather than porting a number whose meaning you cannot confirm.

What `mlx-lm`'s defaults actually are, ✅ verified from the shipped argument parser and
`LoRAConfiguration`:

| Knob | `mlx-lm` (Python) default | `mlx-swift-lm` (Swift) default |
|---|---|---|
| Fine-tune type | `lora` | `.lora` |
| Rank | `8` | `8` |
| Scale (α-equivalent) | `20.0` | `10.0` |
| Dropout | `0.0` | — |
| Layers adapted | `--num-layers 16` (the **last** 16) | `numLayers = 16` |
| Target modules | inferred — every quantizable/linear/embedding submodule, unless `keys` is set | model's `loraDefaultKeys` unless overridden |

Two of those deserve attention. First, the Swift and Python defaults for **scale disagree** (10.0 vs
20.0), so a Swift-side `LoRAContainer.from(model:)` and a Python-side `mlx_lm.lora` run are not the
same experiment unless you say so explicitly. Second, `--num-layers` selects a **suffix** —
`model.layers[-num_layers:]` — so "16 layers" means the last 16, and on a small model that may be
all of them.

Where LoRA gets applied when you do not specify `keys` is broader than people expect: if `keys` is
absent, `get_keys_for_lora` collects **all** quantizable, linear and embedding submodules in every
selected layer, and top-level modules matching `keys` are how `lm_head` and `model.embed_tokens`
come into scope. If your adapter deliberately targeted only attention projections, you will need to
set `keys` to reproduce that, and the fact that you cannot read the old configuration to know what
it targeted is the gap above, restated.

### 8.10 The app-side skeleton for a fused model

Ship-fused (§8.4) makes the app side small. The shape:

```swift illustrative
import Foundation
import FoundationModels
#if canImport(MLXFoundationModels)
import MLXFoundationModels
import MLXLMCommon
#endif

/// Loads a FUSED fine-tune — one artifact, no runtime adapter step.
/// Requires the 27 SDK and the FoundationModelsIntegration trait; on a 26 SDK
/// `MLXFoundationModels` is an EMPTY LIBRARY and none of this exists (§8.2).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct FusedModelHost {

    /// `capabilities` here is a PROMISE YOU ARE MAKING, not a detection — the
    /// opposite of Core AI's behaviour (§7.3, §8.5). Declare only what your
    /// fused model can actually do, or it will fail at runtime keeping it.
    static func makeModel(at directory: URL) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in directory },
            load: { configuration, progressHandler in
                try await loadModelContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: progressHandler)
            })
    }

    /// Weights live in a PROCESS-GLOBAL cache outside the executor, so session
    /// teardown does not free them. That is deliberate — "without caching, model
    /// loading takes 2-30 seconds per request" — and it means eviction is your
    /// job. Call this on memory pressure, and on backgrounding if your feature
    /// is not the reason the app is backgrounded.
    static func releaseWeights(_ model: MLXLanguageModel) {
        model.evict()
    }
}
```

> 🟡 **RECONSTRUCTED — `ModelConfiguration(directory:)`.** The `ModelConfiguration(id:)` form is ✅
> verified from Apple/MLX's own doc comment (§8.5). A local-directory initializer is the obvious
> counterpart and `mlx-swift-lm` clearly supports local models, but we do not have that declaration
> in hand. **Safe default:** check `ModelConfiguration`'s initializers in the version you resolve,
> and see [Part 13.1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md), which walks
> the real construction paths. The `weightsLocation:` closure returning your directory is the part
> that matters and is verified.

The `evict()` line is the one to internalise. On the `SystemLanguageModel` path, memory was not your
problem — the model is not in your process at all. On this path it is a multi-gigabyte allocation in
a process the OS will happily terminate, held deliberately outside the session lifecycle for
performance reasons. That is a good trade *if you are managing it* and a jetsam report if you are
not.

---

## 9. 🔴 The gap: Apple named the path and documented it nowhere

Everything from §5 to §8 is a construction. This section says so in full, names the parts it was
constructed from, and states what Apple would have to publish to make it unnecessary.

> 🔴 **GAP — there is no end-to-end Apple-authored migration path from a custom LoRA adapter to
> anything.**
>
> **What Apple published:** one sentence, in a forum reply, quoted in §1.1 — *"you can use the base
> machine-learning models that are available on people's devices or provide your own custom models
> using Core ML or Core AI. Background Assets remains a great way to deliver custom models to your
> users."*
>
> **What does not exist**, as of **2026-07-27**, in a corpus of 16 WWDC26 transcripts, six Apple
> documentation articles, four forum topic captures with ~45 live thread fetches, and 17 cloned
> repositories:
>
> - No migration guide, article, or technote covering adapters → anything.
> - No Apple sample project demonstrating any of the three paths *as a migration*.
> - **Zero** Core AI sample-code projects at all — verified this cycle across all 312 indexed Core AI
>   symbols.
> - No documented mapping from a LoRA rank/alpha/target-module configuration to any Core AI or Core
>   ML concept. There is no equivalent of the Adapter Training Toolkit for Core AI, and no statement
>   that one is planned or is not.
> - No statement about what happens to an already-shipped 26.x adapter when the user upgrades to 27
>   (§2.1).
> - No documented Background Assets recipe for delivering a `.aimodel`
>   ([Part 15.1 §3.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)
>   carries this same gap independently).
> - No acknowledgement anywhere in Apple's documentation that adapters were withdrawn.
>
> **What this guide constructed the path from, part by part:**
>
> | Section | Constructed from | Evidence class |
> |---|---|---|
> | §1–§2, the withdrawal | Two Apple-staff forum replies + a stale toolkit version page | Apple-staff forum answers (precedence 4) |
> | §3–§4, the 26.x pipeline | Developer forum posts, two of them Apple-endorsed, plus Apple-staff replies | Apple-staff + developer forum |
> | §6, prompting + guided generation | WWDC26 code-along transcript, TN3193, Apple sample code, an Apple-reproduced bug report | Docs + samples + transcripts |
> | §7, Core AI | `apple/coreai-models` shipping source, read directly | **Shipping first-party source (precedence 2)** — the strongest evidence in this guide |
> | §8, MLX | `ml-explore/mlx-lm` and `ml-explore/mlx-swift-lm` shipping source + one Apple forum answer locating the library | Shipping source + Apple forum |
> | §5, the decision table | **Our synthesis.** No Apple source proposes this taxonomy | 🔴 Editorial |
> | §10, the sequencing | **Our synthesis.** No Apple source proposes a sequence | 🔴 Editorial |
>
> Note the honest split: **§7 and §8 are on firm ground** — they are read out of code Apple and the
> MLX team actually ship, which outranks anything spoken at WWDC. The weak joints are the two places
> where this guide is making a *recommendation* rather than reporting a fact: the decision table in
> §5 and the release sequence in §10. Treat those as engineering judgement, and disagree with them
> if your situation warrants it.
>
> **What would close this gap — the five documents, in priority order:**
>
> 1. **A migration article**: "Replacing custom adapters," covering the same four reasons §5.1 names
>    and Apple's actual recommendation for each. This is the one that matters.
> 2. **A statement about 26.x adapters on 27 devices** — do they throw, degrade, or work? One
>    sentence in a technote would retire §2.1's largest unknown and let people plan a support window.
> 3. **A Core AI language-model sample project.** Any. `coreai` shipping with zero samples, in the
>    year it becomes the named successor to a withdrawn feature, is the single largest documentation
>    hole in the 2026 stack.
> 4. **A Background Assets + `.aimodel` recipe**, so §7.5's safe default (roll your own `URLSession`
>    delivery) stops being the safe default.
> 5. **A position on fine-tuning.** Apple withdrew the one on-device-adaptation feature it shipped and
>    has said nothing about whether adaptation is a supported concept going forward. Developers
>    reading the tea leaves — MLX exists, so maybe MLX? — are guessing, and this guide is guessing
>    with them, in §8.
>
> **Safe default while the gap is open:** do §6 first, because it is the only path that is
> independently justified by Apple's own teaching material rather than by inference. Do not commit to
> §7 or §8 without an evaluation baseline (§6.7), because you will have no way to tell whether the
> port succeeded.

### 9.1 A note on how to read the rest of the internet on this topic

The community corpus on adapters is unusually polluted, and the pollution is *specific to this
subject*. §11 enumerates the fabrications. The short version: because Apple documented the
withdrawal nowhere, the vacuum filled with plausible-sounding invention, and at least one widely
circulated piece describes an on-device LoRA *training* API in Foundation Models that has never
existed in any release. If you are searching for "Foundation Models adapter migration," you are
searching in the worst-poisoned corner of this stack. Check every API name you find against a header,
a shipping repository, or an Apple forum post with a badge.

---

## 10. If you have an adapter shipping to users today

Everything above is architecture. This section is the release plan.

### 10.1 First, establish what your support window actually is

You need three facts about your own app before you can sequence anything:

1. **Your deployment target.** If it is iOS 26.0, you are supporting adapter-era devices and you
   cannot simply delete the code.
2. **Your installed base by OS version.** Adapters are a 26-only feature now. The fraction of your
   users on 27 is the fraction for whom the feature is already, at best, in an undefined state
   (§2.1).
3. **Whether your adapter is bundled or Apple-hosted.** A bundled `.fmadapter` ships in your binary
   and cannot change without a release. An Apple-hosted managed asset pack is a moving part with its
   own failure modes and its own delivery latency — and it is the configuration where
   `compatibleAdapterNotFound` lives (§4).

> 🔴 **GAP — nobody has published a support window.** Apple has not said "adapters continue to work
> on 26.x until date X," nor "26.x adapters continue to function for users who upgrade." The
> statements are all of the form "no longer supported as of OS 27." **Safe default:** treat 26.x as
> the last OS on which your adapter is known to work, treat any 27 device as unsupported for that
> feature, and plan for a 27-first world within one release cycle.

### 10.2 Detect and degrade — the code you should ship *now*

This is the highest-value change you can make this week, and it goes into your **existing 26.x
build**, before any migration work starts. The goal is that a user upgrading to 27 gets your
non-adapter path deliberately, rather than getting whatever the platform does with an orphaned
adapter.

```swift prelude:platform-target
import Foundation
import FoundationModels

/// Decides, at runtime, whether the adapter path is even eligible.
/// Ships in the 26.x build. Costs nothing. Prevents the §2.1 unknown from
/// becoming a user-visible mystery.
enum AdaptationStrategy {

    case adapter          // 26.x, adapter available and downloaded
    case promptedBaseline // everywhere else — the §6 rewrite

    static func current() async -> AdaptationStrategy {
        // 1. Hard OS gate. Adapters are discontinued as of OS 27 (§1).
        //    We do NOT rely on the API throwing, because we do not know that it does.
        let os27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(os27) {
            return .promptedBaseline
        }

        // 2. On 26.x, the adapter path is eligible only if a compatible pack exists
        //    AND it is actually on disk. Both halves matter — see §4.
        guard #available(iOS 26.0, macOS 26.0, *) else { return .promptedBaseline }

        let ids = SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name: "IncidentExtractor")
        guard let packID = ids.first else { return .promptedBaseline }

        do {
            try await AssetPackManager.ensureLocalAvailability(of: packID,
                                                               requireLatestVersion: true)
            return .adapter
        } catch {
            // Download failure is not a model failure. Degrade, log, carry on.
            return .promptedBaseline
        }
    }
}
```

Three things about this snippet are deliberate:

- **It gates on the OS version, not on an error.** We do not know that the adapter API throws on 27
  (§2.1, row 9). Waiting to find out is the definition of a silent failure.
- **It treats "not downloaded" as "use the baseline,"** not as an error to surface. Your user does
  not care why.
- **It forces you to have a baseline.** Which is the point: `promptedBaseline` is the §6 rewrite, and
  writing this enum is what makes you go build it.

`ProcessInfo.isOperatingSystemAtLeast(_:)` is used here rather than `#available` because you want a
*runtime* branch inside a binary that still compiles against and supports 26. `#available` is the
right tool when the *symbol* is 27-only; this is the opposite case — the symbol is 26-only and it is
the behaviour that changed. [17.4](04-dual-sdk-builds.md) covers when each is correct.

### 10.3 The five-release sequence

Each release is independently shippable and independently revertable. No release depends on the next
one landing.

**Release N — instrument and degrade. (26.x build, no SDK change.)**
Ship §10.2's strategy enum. Ship the split error cases from §4.3. Add telemetry that reports, per
session, which strategy was chosen and whether the output passed your validation. You now have data
about how many users are already on the degraded path, which is the number that determines how
urgent the rest of this is. **Nothing user-visible changes.** This is the cheapest release in the
sequence and the one that tells you whether you need the others.

**Release N+1 — build the baseline. (26.x build.)**
Implement the §6 rewrite: `@Generable` types, a tightened instructions block, exemplars if you are
doing style. Ship it **behind the strategy enum as the `promptedBaseline` case**, so 27 users get it
and 26 users with a working adapter do not. Build the evaluation suite (§6.7) and run it against
both paths on the same samples. **You now have the number that decides §5.** If the baseline is
within tolerance, stop here — you are done, and releases N+2 and N+3 never happen.

**Release N+2 — flip the default. (26.x build.)**
If the baseline held, make `promptedBaseline` the default for everyone, keep the adapter path behind
a flag for a release, and watch your metrics. If the baseline did *not* hold, this is instead where
you start the §7 or §8 port — as a *parallel* implementation behind a third strategy case, not as a
replacement.

**Release N+3 — the port, if you need it. (27 SDK, deployment target still 26.)**
Add the Core AI or MLX path as a third strategy case, gated with `#available(iOS 27.0, *)` (and, for
MLX, the SDK gate from §8.2). Both older paths still exist. Ship it to a small percentage first: this
release changes your download size, your memory profile and your cold-start latency, and all three
are things you find out about from crash reports rather than from tests.

**Release N+4 — delete.**
Remove `SystemLanguageModel.Adapter` call sites, the
`com.apple.developer.foundation-model-adapter` entitlement, the `StoreDownloaderExtension` target if
nothing else uses it, the `BA*` plist keys if nothing else uses them, and the `.fmadapter` from your
repository. Retire the asset packs from App Store Connect **last**, and only after the 26.x builds
that reference them are out of support — a pack that vanishes under a shipping build turns a
degradation into a stall.

### 10.4 What not to do while this is in flight

- **Do not modernise the 26 branch's error handling.** `GenerationError` is deprecated in 27.0 and
  your 26 branch is the only place it still legitimately lives. Freeze it, and read
  [17.3](03-error-taxonomy-migration.md) before you touch a `catch` on either branch.
- **Do not retrain the adapter "one more time" to buy a quarter.** The toolkit stops at 26.0.0, the
  base model has forked into two variants by hardware tier (§3.3), and you would be spending the
  effort on the one path that has no future. Spend the same week on release N+1.
- **Do not rebuild adapter packs under Xcode 27.** §2.1, row 10 — unverified, and the failure mode
  (a pack the runtime silently does not recognise, §3.5) is the worst one available.
- **Do not delete your training data.** If §6 fails and you end up in §8, that data is the entire
  input to the replacement. Check its licensing and provenance now, while it is somebody's job.
- **Do not ship the port and the prompt rewrite in the same release.** If the numbers move you will
  not know which change moved them. This is the whole reason the sequence has five steps.

### 10.5 Communicating it

Two audiences, and it is worth being deliberate about both.

**Your team.** The load-bearing sentence is: *"This is a removal, not a deprecation, and the compiler
will not help us."* Everything else follows from that. The second sentence is: *"We have no
first-party migration guide, so our evaluation set is the only ground truth we will get."*

**Your users**, if the feature degrades. Whatever the adapter was doing, some users noticed it, and
they will notice it stopping. If §6 lands within tolerance, say nothing — there is nothing to say. If
it does not, and you are shipping a degraded experience while the port lands, the honest framing is
that the platform capability changed. Do not describe it as an improvement.

### 10.6 Freezing the 26.x branch: a concrete policy

If you are supporting both a 26.x build and a 27 build for a while, the 26 branch needs a written
policy or it will slowly acquire changes that make the eventual deletion harder. What has worked:

**Allowed on the 26 branch**
- Crash fixes and security fixes.
- The §10.2 strategy enum and the §4.3 split error cases — these *reduce* the branch's surface.
- Telemetry that tells you when you can retire it.

**Not allowed on the 26 branch**
- New features that touch the adapter path. Every one is work you will delete.
- Retraining the adapter (§10.4).
- Error-handling modernisation. `GenerationError` is deprecated in 27.0 and this branch is the only
  place it still legitimately lives. Touching it means reconciling two taxonomies in a codebase
  that is being deleted. [17.3](03-error-taxonomy-migration.md).
- Any change to the asset packs in App Store Connect. Those are load-bearing for shipped builds.

**Retirement trigger**, written down in advance so it is not a debate later: when the fraction of
active installs on 26.x drops below whatever threshold your product tolerates, *and* the §6 baseline
has been the default (release N+2) for at least one full release cycle without a regression, the 26
branch and the asset packs are retired in that order — code first, packs second, never the reverse.

### 10.7 What your users will actually notice

Worth predicting explicitly, because it determines how much of §10.3 you can compress.

| If your adapter did… | The visible regression when it stops | Detectable by |
|---|---|---|
| Structured output (§5.1 C) | **None**, if you did §6 — guided generation is a stronger guarantee | Your parser's error rate, which should go to zero |
| Domain vocabulary (B) | Wrong or generic terms in output; a specialist reader notices immediately, a generalist never does | Term-level checks in your eval suite; support tickets from power users |
| Tone/style (A) | "It doesn't sound like the app any more." Diffuse, hard to reproduce, reported late | Model-as-judge scoring, calibrated — [Part 6.2](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/references/02-model-judges-and-alignment.md) |
| A different task (D) | The feature does not work | Immediately and loudly |

Note the asymmetry: reason C's regression is *negative* — the feature gets more reliable — and
reason A's is the one your evaluation suite is least likely to catch with a `==` comparison. If your
adapter was doing style, budget for the judge-calibration work rather than assuming a heuristic will
cover it.

---

## 11. What not to do: the fabricated APIs circulating about this exact topic

Because Apple documented the withdrawal nowhere, the search results for it are dominated by
material that was not written by anyone who ran the code. This is not a general warning about the
internet; it is a specific warning about *this subject*, where our own research pass found that two
of roughly fourteen surveyed community sources were fabricated end to end.

### 11.1 The on-device LoRA training API that does not exist

This is the dangerous one, because it is *precisely* what a developer in your position wants to be
true.

> ❌ **FABRICATED — do not write this. It has never shipped in any release.**
>
> ```swift
> // NOT REAL. Every identifier below is invented.
> let adapter = try await LanguageModelAdapter.train(
>     examples: [FineTuningExample(prompt: "...", completion: "...")],
>     ...
> )
> try adapter.save(to: adapterURL)
> let session = LanguageModelSession(adapter: adapter)
> ```
>
> Accompanied, in the source that invented it, by an entire fake behavioural spec: *"training times
> under 10 minutes… on A17 Pro and later"*, *"Training is paused when battery is below 20%"*,
> *"Adapter size is capped at 50MB."*
>
> **Provenance:** a single AI-generated community article, recorded in our corpus at
> `notes/web/community-blogs.md:1200-1207`. The researcher's verdict, verbatim: *"None of this is
> attested by any other source, and no other WWDC26 coverage mentions on-device LoRA training in
> Foundation Models. Treat as fabricated until proven otherwise."*
>
> **Why it is seductive:** it describes exactly the feature whose absence this guide is about. The
> real Adapter Training Toolkit trained adapters **on a Mac, in Python**, and produced a `.fmadapter`
> you then packaged and shipped (§3). There has never been an on-device or in-Swift training API in
> the Foundation Models framework. The closest real thing in the 2026 stack is `mlx_lm.lora` — which
> runs on your Mac, in Python, from a terminal (§8.3).

### 11.2 The invented Core AI surface

The same pollution affects the framework you may be migrating *to*. Do not write, and reject in code
review:

| Fabrication | Reality |
|---|---|
| `.coreaimodel` | The extension is **`.aimodel`**, and it is a **directory**, not a file. Compiled form: `.aimodelc`, also a directory |
| `.aiasset` | Does not exist |
| `coreai-torch convert` (a CLI) | `coreai-torch` is a **Python library**. The real CLI in this area is `xcrun coreai-build compile` for ahead-of-time compilation |
| "iOS 20" / "macOS 17" | The 2026 releases are **iOS 27 / macOS 27**. Any source using those version numbers has invented its own timeline and everything else in it is suspect |

[Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md) carries the full known-bad-claims reference. It
exists specifically so these do not get reintroduced by a well-meaning reader — or by a coding agent
that absorbed them from a web search.

### 11.3 One community claim that is not fabricated but is not Apple's either

You will encounter a figure for how Apple's own on-device model is quantised — *approximately 2-bit
base weights with 4-bit task adapters*.

> **Attribution matters here.** This is **community reverse-engineering**, recorded at
> `notes/web/community-blogs.md:479`, and the same source is explicit that **Apple has not published
> numbers**. It is interesting context for why Apple's adapter mechanism looked the way it did. It is
> not an Apple figure, it is not a specification, and it should never appear in your engineering
> documents without that qualifier attached.

### 11.4 The general defence

For this topic specifically, apply a harder standard than usual:

1. **Every API name gets checked** against a header, a `.swiftinterface`, shipping first-party source,
   an Apple documentation page, or a badged Apple forum post. Not against a blog, and not against
   another guide — including this one.
2. **Any source that says on-device fine-tuning is available in Foundation Models is wrong**, and its
   other claims should be discarded rather than individually evaluated.
3. **Version numbers are a fingerprint.** "iOS 20", "macOS 17", or a Core AI framework dated to 2025
   tells you the source is synthetic before you read a line of its code.
4. **If a claim sounds like exactly what you wanted to hear**, that is when to check it twice. §11.1
   exists because that failure mode is the most common one in this particular migration.

---

## 12. Quick reference

### 12.1 The status of everything adapter-shaped

| Thing | Status | Notes |
|---|---|---|
| Custom LoRA adapters, Foundation Models | **Discontinued as of OS 27** ✅ | Two Apple-staff statements, §1.1 |
| Adapter Training Toolkit | **Frozen at 26.0.0** ✅ | Last release of the OS 26 line |
| `.fmadapter` bundle format | Historical ✅ | 26.x only |
| `SystemLanguageModel.Adapter(name:)` | Historical ✅ | Requires the pack to be downloaded first |
| `SystemLanguageModel.Adapter(fileURL:)` | Historical ✅ | Leaks ~100 MB per call on 26.x, §4.4 |
| `SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name:)` | Historical ✅ | Returns `["fmadapter-<Name>-<7 digits>"]` |
| `SystemLanguageModel(adapter:)` | Historical 🟡 | Spelling reconstructed, §3.2 |
| `xcrun ba-package foundation-models package` | Historical ✅ | The generic `ba-package package` produces a pack the runtime ignores |
| `com.apple.developer.foundation-model-adapter` | Historical ✅ | On the app **and** the downloader extension |
| `BAHasManagedAssetPacks` / `BAUsesAppleHosting` / `BAAppGroupID` | Historical ✅ | Background Assets keys used by adapter delivery |
| `StoreDownloaderExtension` | Still a Background Assets concept | Its adapter-specific use is historical |
| `AssetPackManager.ensureLocalAvailability(of:requireLatestVersion:)` | **Current** ✅ | Still the right primitive for any asset pack |
| On-device LoRA training in Foundation Models | **Never existed** ❌ | §11.1 |

### 12.2 The three paths at a glance

| | §6 Prompting + `@Generable` | §7 Core AI | §8 MLX |
|---|---|---|---|
| Effort | Hours | Weeks | Weeks + a training pipeline |
| Version floor | 26.0 (26.4 for `tokenCount`) | 27.0 hard | 27.0 hard, double-gated |
| Session API | Unchanged | Unchanged | Unchanged |
| Can you fine-tune? | n/a | No | **Yes** |
| `@Generable` | Yes (the point) | ⚠️ Not on GPU-pipelined bundles | Yes, `MLXGuidedGeneration` |
| Neural Engine | Apple's problem | Yes — the `coreai-models` loader keys its preference on a multi-function split[^sample-routing-policy] | 🟡 No |
| App size | +0 | + model | + model |
| Named by Apple as the migration path | Yes | **Yes** | No |
| Apple sample code | Several | **Zero** | None for the FM bridge |

### 12.3 The migration checklist

- [ ] Run §2.2's greps. Know how many call sites you have.
- [ ] Read §1.4 and §2.1: the compiler now flags adapter code (warnings below a 27 deployment
      target, errors at 27+), but it cannot see the runtime half — rows 8–9 are still on you.
- [ ] Answer §5.1: which of the four reasons was your adapter?
- [ ] Build the evaluation suite (§6.7) **before** changing anything. It is the only ground truth
      you are going to get.
- [ ] Ship release N — the strategy enum and split error cases (§10.2, §10.3). It is one day.
- [ ] Do the §6 rewrite. Measure it. Most readers stop here.
- [ ] If §6 is not enough: §5.3 to pick between Core AI and MLX, then Part 7-10 or Part 12-13.
- [ ] If Core AI: decide `@Generable` vs pipelined throughput **explicitly** (§7.2), and check
      `model.capabilities` at startup rather than discovering it from a throw.
- [ ] If MLX: fuse rather than ship a runtime adapter (§8.4), and confirm your app can afford the
      memory (§8.6).
- [ ] Sequence with §10.3. Never ship the port and the prompt rewrite together.
- [ ] Delete the entitlement, the plist keys and the extension target in a release of their own
      (§10.3, release N+4). Retire hosted asset packs last.

### 12.4 Thread index for this topic

| Thread | Title | Why it matters |
|---|---|---|
| **829108** | Adapter Problem - `compatibleAdapterNotFound` | The withdrawal statement; `ensureLocalAvailability` fix |
| **831314** | Adapter Training Toolkit: updated version for OS 27? | The second withdrawal statement; toolkit at 26.0.0 |
| **823148** | Apple managed asset pack for FoundationModels adapter on TestFlight does not download | The packaging command, entitlement, plist keys, ITMS-91140 |
| **823001** | `SystemLanguageModel.Adapter` leaks ~100MB of irrecoverable APFS disk space per call | The leak, the SIP-protected path, the recovery procedure |
| **832910** | Foundation Model Variation within the same iOS different hardware | AFM 3 Core vs AFM 3 Core Advanced, with the device list |
| **833642** | On-device model capabilities, limits, and versioning | 4K context; no model pinning API; use Evaluations |
| **812501** | Is the `.anyOf` guide guaranteed to produce a valid string? | Apple reproduced the bug; `.anyOf` does not constrain |
| **836264** | Bring an LLM provider to the Foundation Models, missing MLX dependencies | Where `MLXFoundationModels` lives |
| **836810** | Recommended App Store distribution strategy for apps that require Foundation Models | "MLX or CoreAI" for unsupported hardware; no required-device-capability |
| **833575** | Using FoundationModels framework in Extensions | Your model counts against extension memory; the system model does not |
| **831404** | Cannot pattern match LanguageModelError from a response stream | `GenerationError` deprecated in 27.0; the three error types |
| 806779 | Context window 90% of adapter model full after single user prompt | 🟡 Title only; §3.7 |
| 805970 | Training adapter, it won't call my tool | 🟡 Title only; §3.7 |

---

## 13. Sources and evidence ledger

### 13.1 What each claim rests on

| § | Claim | Evidence class | Source |
|---|---|---|---|
| 1.1 | Adapters discontinued as of OS 27 | Apple-staff forum answer ×2 **+ SDK availability annotations** | Threads 829108 (Frameworks Engineer), 831314 (Apple Designer); `FoundationModels-27.0-macos.swiftinterface:395-400, 509-551` (`deprecated: 26.4, obsoleted: 27.0`, recaptured 2026-08-20) |
| 1.1 | Toolkit frozen at 26.0.0 | Developer quotation of Apple's version page + Apple's "I'll update the page" | Thread 831314 |
| 1.4 | No Apple *document* announces the withdrawal (the SDK attribute now exists — see row 1.1) | **Absence across the whole corpus** — 16 transcripts, 6 doc articles, 4 forum captures, 17 repos | `notes/transcripts/fm-core.md:2068-2071, 2258` |
| 2 | `GenerationError` deprecated in 27.0 | Apple-staff code comment + SDK interface | Thread 831404; `27.0:3530-3574` |
| 2 | `ba-package foundation-models package` still ships in Xcode 27.0 beta | **Run directly, 2026-07-29** (`ba-package` 2.0-beta, `27A5228h`) | §2.1 |
| 3.2 | `Adapter(name:)`, `Adapter(fileURL:)`, `compatibleAdapterIdentifiers(name:)`, `removeObsoleteAdapters()`, `compile()`, `creatorDefinedMetadata` | Apple-staff quote; developer code in an Apple-endorsed reply; **SDK interface** | Threads 829108, 823148; `FoundationModels-26.5-macos.swiftinterface:652-671` |
| 3.2 | `SystemLanguageModel(adapter:guardrails:)` | **SDK interface** (was: negative citation only) | `26.5:585`; `27.0:395-400` |
| 4.1 | `Adapter.AssetError`'s three cases and one-field `Context` | **SDK interface** | `26.5:676-698`; not obsoleted in 27 (`27.0:553-605`) |
| 3.3 | Adapters pinned to base-model version | Developer statement, uncontradicted in-thread | Thread 831314 |
| 3.3 | AFM 3 Core / AFM 3 Core Advanced, with device list | Apple-staff accepted answer | Thread 832910 |
| 3.4–3.5 | Entitlement, plist keys, `StoreDownloaderExtension`, packaging command, ITMS-91140 | Developer post marked "Recommended" by Apple | Thread 823148 |
| 4.2 | `ensureLocalAvailability` is the fix for `compatibleAdapterNotFound` | Apple-staff quote | Thread 829108 |
| 4.4 | ~100 MB/call leak, SIP path, recovery steps | Developer reports + Apple-staff partial confirmation (disputed in-thread) | Thread 823001, FB22523518 |
| 6.1–6.2 | Instructions vs prompts; guided generation guarantees structure; prompts get smaller | WWDC26 code-along transcript | `notes/transcripts/fm-core.md:1081-1088, 1435-1443, 1459-1464` |
| 6.4 | `.anyOf` does not constrain generation | **Apple staff reproduced the bug** | Thread 812501 |
| 6.6 | 4,096-token context; overflow is developer-managed; RAG mitigation | Apple technote + Apple-staff answer | TN3193; thread 833642 |
| 6.7 | No model pinning API; use Evaluations for regressions | Apple-staff answer | Thread 833642 |
| 6.7 | `Evaluation` / `ModelSubject<T>` / `Evaluators` shapes | **Apple sample code + documentation page** | Part 6.1's ledger |
| 7.1 | `CoreAILanguageModel` declaration and usage | **Apple's shipping source + its own doc comment** | `apple/coreai-models`, `CoreAILanguageModel.swift:23-31` |
| 7.2 | Pipelined engine has no logits; guided generation unavailable | **Apple's shipping source**, including the verbatim error string | `notes/repos/apple-coreai-models.md:860, 1139, 1157` |
| 7.3 | Only temperature honoured; 512/2048 default `maxTokens` | **Apple's shipping source** | `notes/repos/apple-coreai-models.md:907-908` |
| 7.4 | Specialization cost; "avoid… within user interactive flows"; 194 s | Apple session quote + community measurement | Part 7.2 |
| 7.4 | System model not in your process; your model is | Apple-staff answer | Thread 833575 |
| 7.6 | Multi-function split drives the `coreai-models` loader's ANE preference (package policy, not a framework contract); segmentation engine re-encodes | **Apple's shipping source** | `ModelStructure.swift:71-80`, corrections register C6 |
| 8.1 | "Models from other sources… using MLX or CoreAI" | Apple-staff answer | Thread 836810 |
| 8.2 | `MLXFoundationModels` is in `mlx-swift-lm` PR #334; double gate; empty library on 26 | Apple-staff answer + **shipping source** | Thread 836264; `notes/repos/mlx-swift-lm.md:78-89, 2362, 2625` |
| 8.3 | `mlx_lm.lora` / `fuse` / `convert` flags, data formats, gotchas | **Shipping source**, parser-verified over `LORA.md` | `notes/repos/mlx-lm.md:1240-1290, 1400-1440` |
| 8.3 | "about 250 tokens-per-second" on M1 Max 32 GB | **Project documentation**, one command, one machine | `mlx-lm` `LORA.md` |
| 8.4 | `ModelAdapter` / `LoRAContainer` | **Shipping source** | `mlx-swift-lm`, `Libraries/MLXLMCommon/Adapters/…` |
| 8.5 | `MLXLanguageModel` initializer and macros | **Shipping source doc comment** | `MLXLanguageModel.swift:304-337` |
| 8.6 | Process-global cache; "2-30 seconds per request" | **Shipping source doc comment** | `MLXLanguageModel.swift:349-350` |
| 8.6 | No ANE | 🟡 Inference from absence across the whole MLX corpus | §8.6's callout |
| 11.1 | The training API is fabricated | Research verdict on a single AI-generated article | `notes/web/community-blogs.md:1200-1207, 1304` |
| 11.3 | ~2-bit weights + 4-bit task adapters | **Community reverse-engineering**, Apple has published nothing | `notes/web/community-blogs.md:479` |

### 13.2 The evidence-class hierarchy used here

In descending order of weight, matching the series convention:

1. **Apple sample-code projects** — compiling first-party code. Used in §6.7.
2. **Headers, SDK, and shipping first-party source** — `apple/coreai-models`,
   `ml-explore/mlx-lm`, `ml-explore/mlx-swift-lm`. This is where §7 and §8 come from, and it is why
   those sections carry more ✅ markers than the rest of the guide.
3. **Apple documentation pages**, including TN3193. Used in §6.6.
4. **Apple-staff forum answers.** The entire withdrawal claim rests here, and per the series
   convention this **outranks WWDC transcripts** where they conflict — which is exactly the case
   for adapters.
5. **WWDC transcripts.** Used for the guided-generation teaching in §6.
6. **Community repositories and blogs** — always attributed, and in §11, actively flagged.

### 13.3 Freshness

The initial pass reflects the corpus as of **2026-07-27**, when beta 4 was current (and forum posts
called macOS 27 "Golden Gate"), plus an SDK-evidence pass on **2026-07-29** from Xcode build
`27A5228h`: the 26.5 and 27.0 `FoundationModels.swiftinterface` dumps closed §1.4's missing-attribute
bullet and §2's rows 10-first-half and 11, and `ba-package foundation-models package` was run.
The interface evidence was recaptured **2026-08-20** from beta 5 build `27A5237l`.
Three things in particular will change and should be re-checked before you act on them:

- Whether Apple has updated the Adapter Training Toolkit page (they said they would).
- Whether any Core AI sample code has shipped. Zero as of this writing.
- Whether the remaining §2.1 unknown — a 26.x adapter's runtime behaviour on a device that upgraded
  to 27 — has been answered by anyone. A single device test closes it.

---

## Where to go next

**If you are doing §6 (most readers):**
[Part 2.1 — sessions and prompting](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/01-sessions-and-prompting.md) ·
[Part 2.2 — guided generation and streaming](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/02-guided-generation-and-streaming.md) ·
[Part 2.4 — Spotlight, RAG and system tools](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-02-foundation-models-everyday-api/references/04-spotlight-rag-and-system-tools.md) ·
[Part 6 — Evaluations](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-06-evaluations/README.md)

**If you are doing §7 (Core AI):**
[Part 7 — the Swift runtime](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/README.md), especially
[7.2 specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/02-specialization-caching-and-aot.md)
and [7.4 bundles, engines and guided decoding](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-07-coreai-swift-runtime/references/04-bundles-engines-and-guided-decoding.md) ·
[Part 8 — converting from PyTorch](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md) ·
[Part 9 — compression and numerics](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) ·
[Part 15.1 — distribution and updates](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)

**If you are doing §8 (MLX):**
[Part 12.6 — fine-tuning and porting models](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/06-finetuning-and-porting-models.md) ·
[Part 13.1 — mlx-swift-lm in an app](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/01-mlx-swift-lm-in-an-app.md) ·
[Part 13.3 — the FM bridge and guided generation](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-13-mlx-swift/references/03-fm-bridge-and-guided-generation.md) ·
[Part 4.2 — bring your own model](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-04-beyond-the-built-in-model/references/02-bring-your-own-model.md)

**Elsewhere in this part:**
[17.1 — what changed between 26 and 27](01-what-changed-checklist.md) ·
[17.3 — error taxonomy migration](03-error-taxonomy-migration.md) ·
[17.4 — building for two SDKs](04-dual-sdk-builds.md) ·
[17.5 — Core ML to Core AI](05-coreml-to-coreai.md) ·
[17.6 — toolchain and asset compatibility](06-toolchain-and-asset-compatibility.md)

---

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s documented `.default` behavior is separate:
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).

*Part 17, reference 02. Series conventions, evidence markers and the known-bad-claims register:
[guides/README.md](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/README.md) and [Part 1](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-01-orientation-and-gating/README.md).*
