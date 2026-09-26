# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 16 — Adjacent capabilities

### 16.1 — SpeechAnalyzer: live transcription, assets, and custom vocabulary

The 2026 speech-to-text stack end to end: an actor owning analysis modules, fed one time-coded audio sequence, handing each module's output back as its own `AsyncSequence` — with **no accumulated transcript**, because assembling the document is your job.

**Local reference:** [part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md](part-16-adjacent-capabilities/references/01-speech-analyzer-end-to-end.md)

| Section | Anchor |
|---|---|
| Evidence markers used in this guide | `#evidence-markers-used-in-this-guide` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. Two warnings before you write any code | `#1-two-warnings-before-you-write-any-code` |
| 2. The shape of the pipeline | `#2-the-shape-of-the-pipeline` |
| 3. Choosing a transcriber | `#3-choosing-a-transcriber` |
| 4. Presets, options, and content hints | `#4-presets-options-and-content-hints` |
| 5. Assets: `AssetInventory` and the reservation quota | `#5-assets-assetinventory-and-the-reservation-quota` |
| 6. Input: `CaptureInputSequenceProvider` and friends | `#6-input-captureinputsequenceprovider-and-friends` |
| 7. Running the analysis | `#7-running-the-analysis` |
| 8. Result merging: the subtle part | `#8-result-merging-the-subtle-part` |
| 9. ⚠️ The cancellation shield | `#9-️-the-cancellation-shield` |
| 10. A complete worked example | `#10-a-complete-worked-example` |
| 11. Custom vocabulary and custom language models | `#11-custom-vocabulary-and-custom-language-models` |
| 12. `SpeechDetector`: gating on voice activity | `#12-speechdetector-gating-on-voice-activity` |
| 13. Resource limits, model retention, prewarming | `#13-resource-limits-model-retention-prewarming` |
| 14. The other path: `CoreAISpeech` and Whisper on Core AI | `#14-the-other-path-coreaispeech-and-whisper-on-core-ai` |
| 15. Declared gaps | `#15-declared-gaps` |
| 16. Silent-failure checklist | `#16-silent-failure-checklist` |
| 17. Sources | `#17-sources` |
| Related guides | `#related-guides` |
