# Silent-failure index — SpeechAnalyzer: live and file-based transcription

**42 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Empty output / no-op](#empty-output--no-op) | 4 |
| [Truncation & limits](#truncation--limits) | 6 |
| [Ignored input](#ignored-input) | 2 |
| [Compiles but unavailable](#compiles-but-unavailable) | 5 |
| [Version drift](#version-drift) | 2 |
| [Docs vs reality](#docs-vs-reality) | 4 |
| [API footguns](#api-footguns) | 7 |
| [General cautions](#general-cautions) | 12 |

## Empty output / no-op

**Part 16**

- [The sample forwards preset.attributeOptions unchanged and progressiveLongDictation omits .audioTimeRange — no merge data](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#44-content-hints--dictationtranscriber-only) — 16.1
- [Query bestAvailableAudioFormat before assets install and it silently returns nil — ?? default hides the ordering bug](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#55-what-breaks-if-you-skip-assets-entirely) — 16.1 🔇
- [Code comment: AnalyzerInputConverter returns nil unless assets are already installed (§5.5)](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#66-when-you-still-need-analyzerinputconverter) — 16.1
- [Without audio time ranges strategy A silently degrades to append-only — the replace-by-range merge never fires](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#83-️-silent-failure-strategy-a-silently-degrades-to-append-only) — 16.1

## Truncation & limits

**Part 16**

- [Cancel the display task and the transcriber's final updates go unread — every recording's last phrase lost, no error](part-16-adjacent-capabilities/README.md#161--speechanalyzer-live-transcription-assets-and-custom-vocabulary) — 16.README 🔇
- [TOC: cancelling the display task drops the final results — the tail of every recording is silently lost](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#what-this-covers) — 16.1
- [Contents: the cancellation shield — the guard against losing each recording's final phrase](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#contents) — 16.1
- [Code comment: without the shield you lose the tail of every recording](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#64-complete-microphone-capture-end-to-end) — 16.1
- [The cancellation shield: stop reading at cancel time and the final updates — the recording's tail — are lost](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#9-️-the-cancellation-shield) — 16.1
- [Code comment: the shield is an unstructured Task so display outlives cancellation and reads the final results](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#10-a-complete-worked-example) — 16.1

## Ignored input

**Part 16**

- [Unsupported phoneme symbols are silently ignored — validate against supportedPhonemes(locale:) at build time](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#113-the-sfcustomlanguagemodeldata-dsl) — 16.1
- [Four of six failure rows give working transcription that ignores your vocabulary — invisible unless you speak jargon](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#117-failure-modes) — 16.1 🔇

## Compiles but unavailable

**Part 16**

- [AnalyzerInput's sample-buffer initializer is iOS 27.0+ — adopting it raises your OS floor](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#67-analyzerinput-itself) — 16.1
- [bufferDuration is iOS 27.0+ only](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#67-analyzerinput-itself) — 16.1
- [bufferFormat is iOS 27.0+ only](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#67-analyzerinput-itself) — 16.1
- [The priority/modelRetention/ignoresResourceLimits initializer is iOS 27.0+](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#132-model-retention) — 16.1
- [ignoresResourceLimits is iOS 27.0+ only](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#132-model-retention) — 16.1

## Version drift

**Part 16**

- [AnalyzerInput.buffer is deprecated — read format and duration via the new iOS 27 properties](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#67-analyzerinput-itself) — 16.1
- [The clientIdentifier: prepare overloads are deprecated — migrate off them](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#115-stage-2-preparing-the-model-on-device) — 16.1

## Docs vs reality

**Part 16**

- [The downloadable SpeechAnalyzer sample is the WWDC25 leftover — stale for the 2026 APIs](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#12-the-speechanalyzer-sample-project-is-a-wwdc25-leftover) — 16.1
- [Don't verify the 2026 API from the downloadable sample — it compiles and runs but teaches only iOS 26 patterns](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#12-the-speechanalyzer-sample-project-is-a-wwdc25-leftover) — 16.1
- [Apple's option-enum snippet is missing commas and does not compile as printed](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#43-the-option-enums-and-how-to-modify-a-preset) — 16.1
- [Two Apple pages describe an impossible config: merge progressiveLongDictation by time range, but it emits none](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#83-️-silent-failure-strategy-a-silently-degrades-to-append-only) — 16.1 🔇

## API footguns

**Part 16**

- [finish() alone never terminates the result streams — 'for try await result' waits forever and the stop button hangs](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#23-what-finished-means) — 16.1 🔇
- [assetInstallationRequest is nil on already-provisioned devices — force-unwrap and you crash exactly where all is fine](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#53-the-four-step-process-and-the-ordering-that-matters) — 16.1 🔇
- [A local withTaskCancellationShield shadows the Swift 6.4 stdlib function with different generics and no async/sync…](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#94-what-withtaskcancellationshield-actually-is) — 16.1
- [Code comment: the installation request is nil when assets are already installed — never force-unwrap](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#10-a-complete-worked-example) — 16.1
- [SpeechDetector.Result is not speech/silence events — the name promises what the stream doesn't carry](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#123-️-speechdetectorresult-is-not-what-its-name-suggests) — 16.1
- [speechDetector.results carries only VAD model errors per Apple's docs — subscribe for speech events and get none](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#123-️-speechdetectorresult-is-not-what-its-name-suggests) — 16.1 🔇
- [ignoresResourceLimits trades a clean, catchable error for nondeterministic failure at an unknown threshold](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#131-️-there-is-a-cap-on-simultaneous-analyzers) — 16.1 🔇

## General cautions

**Part 16**

- [Read-first: two planning-level facts gate everything in this part — learn them before scoping work](part-16-adjacent-capabilities/README.md#️-two-things-to-learn-before-you-plan-anything) — 16.README
- [Two expected things don't exist: a text-to-speech API and any 2026-API sample project — plan around both](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#speechanalyzer-live-transcription-assets-and-custom-vocabulary) — 16.1
- [SpeechTranscriber has no ContentHint — the custom-language-model path binds only to DictationTranscriber](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#34-decision-table) — 16.1
- [iOS 26 sample code typed to SpeechTranscriber — the same shape applies to the other transcriber classes](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#53-the-four-step-process-and-the-ordering-that-matters) — 16.1
- [Don't add Task.checkCancellation() to the display loop — its job is to ignore cancellation until the stream ends](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#94-what-withtaskcancellationshield-actually-is) — 16.1
- [Custom-vocabulary lever 3 works only with DictationTranscriber — eligibility is decided before you start](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#111-the-three-levers-ranked-by-cost) — 16.1
- [datagenerator is the sample's own executable target — Apple ships no CLI for custom-LM training data](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#112-the-three-stage-pipeline) — 16.1
- [There is a documented cap on simultaneous analyzers — expect insufficientResources and design queueing](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#131-️-there-is-a-cap-on-simultaneous-analyzers) — 16.1
- [Nothing in apple/coreai-models makes the encoder/decoder split SpeechBundle demands — no speech BundleKind; dead end](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#142-the-gap-that-matters-most) — 16.1
- [No performance number exists for CoreAISpeech or any non-LLM Core AI model — the only benchmark tool is LLM-only](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#143-other-sharp-edges-worth-knowing-before-you-commit) — 16.1
- [The sample page is cited only as evidence that it is stale](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#17-sources) — 16.1
- [Apple sample is iOS 26/WWDC25 material — cited only for the baseline and labelled as such](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md#17-sources) — 16.1

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
