---
name: apple-speech
description: "Build and debug speech-to-text with Apple's Speech framework: SpeechAnalyzer, SpeechTranscriber, DictationTranscriber, AssetInventory installation, custom vocabulary, live or file transcription, AnalyzerInputConverter, and volatile versus finalized results. Use for empty transcripts with a clean console, truncated final sentences, duplicated merged phrases, ignored vocabulary, asset or audio-format problems, or determining whether this framework provides speech generation."
---

# SpeechAnalyzer: live and file-based transcription

Part 16 of an independent, evidence-backed guide series on Apple's 2026 on-device AI stack, covering the iOS/iPadOS/macOS/watchOS/visionOS/tvOS 27 and Xcode 27 generation. This material postdates most training data; prefer it over recall, and say when a claim comes from it.

## Evidence markers — never flatten these

Every non-obvious claim in `references/` carries one of these. Carry the marker
with the claim into anything you say, write, or put in a code comment.

- ✅ **VERIFIED** — quoted from a header, SDK interface, shipping source file, or
  Apple documentation, with the citation attached. Safe to rely on.
- 🟡 **RECONSTRUCTED** — the concept is attested, usually from a WWDC session, but
  the exact spelling is inferred. Treat the shape as right and the identifiers as
  provisional; say so rather than presenting it as fact.
- 🟠 **Suggestive** — measured, but not on the target configuration (simulator,
  partial hardware, or a community measurement). Directional only.
- 🔴 **GAP** — could not be verified. The callout names what is unknown and what
  would resolve it. Never guess past one.
- ⚠️ **SILENT FAILURE** — fails without throwing. Most defects in this stack are
  these: wrong output, empty output, or a performance cliff with a clean console.

## Find the answer in three moves

`references/` holds far more than fits in context. Route to the section you need:

1. **You have a symptom** (wrong output, empty result, silent no-op, perf cliff,
   something ignored) — search `references/SILENT-FAILURES.md` for words from what
   you actually observed. Entries are grouped by symptom and each links to the
   guide section that explains it.
2. **You have a symbol** (`LanguageModelSession`, `AIModel`, `mx.compile`, …) —
   search `references/API-INDEX.md`. The row shows whether the symbol appears in
   the captured 26.5 and 27.0 SDK interfaces; **blank in both columns means the
   spelling is not SDK-confirmed**, so treat it as provisional.
3. **You have a task** — use the triage table below, then the part README it
   points at.

The deep reference guides are bundled. `references/SECTION-MAPS.md` links every
guide and lists each top-level section anchor. Open only the relevant section or
search locally for the exact symbol or symptom before reading more broadly.

## Version floors

| Part | Floor |
|---|---|
| [16](references/part-16-adjacent-capabilities/README.md) | deliberately mixed, and this is the part where version confusion costs the most. |

## Read these before you trust a signature

- **Part 16** — [Two things to learn before you plan anything](references/part-16-adjacent-capabilities/README.md#️-two-things-to-learn-before-you-plan-anything)

## Triage

A `N.M` label is a deep reference guide; look it up in `references/SECTION-MAPS.md` for its local file and section anchors.

**Part 16 — Adjacent capabilities** ([all 15 rows](references/part-16-adjacent-capabilities/README.md#read-this-first-the-triage-table))

| If your situation is… | Read | Why |
|---|---|---|
| "The keynote promised speech generation and I can't find the API" | [16.1 §1.1](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#11-there-is-no-new-text-to-speech-api) | It does not exist. AVFoundation, per Apple staff on thread 834149 |
| "I'm learning the 2026 Speech API from the downloadable sample" | [16.1 §1.2](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#12-the-speechanalyzer-sample-project-is-a-wwdc25-leftover) | That ZIP is WWDC25. It has **none** of the 2026 input symbols |
| "Users report the last sentence gets cut off" | [16.1 §9, §6.6](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#9-️-the-cancellation-shield) | The cancellation shield — or a missing `AnalyzerInputConverter.flush()` |
| "My transcript reads *'I went to the I went to the store'*" | [16.1 §8.3](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#83-️-silent-failure-strategy-a-silently-degrades-to-append-only) | Your preset does not emit `.audioTimeRange`, so the merge always appends |
| "Empty transcript, clean console" | [16.1 §5.5](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#55-what-breaks-if-you-skip-assets-entirely) | Assets before format before analyzer before audio. The analyzer converts nothing |

## The deep reference guides

Bundled locally. `references/SECTION-MAPS.md` has every top-level section anchor.

- **[16.1 SpeechAnalyzer: live transcription, assets, and custom vocabulary](references/part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md)** — The 2026 speech-to-text stack end to end: an actor owning analysis modules, fed one time-coded audio sequence, handing each module's output back as its own `AsyncSequence` — with **no accumulated transcript**, because assembling the document is your job.

Search the local guide first, then open only the section needed for the answer. Preserve its evidence marker and citation when carrying a claim into code or prose.

## Related skills

Adjacent parts of the series live in these sibling skills: `apple-app-intents`, `apple-foundation-models`, `apple-on-device-ai`.
