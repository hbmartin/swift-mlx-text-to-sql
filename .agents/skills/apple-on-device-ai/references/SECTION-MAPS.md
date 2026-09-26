# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 1 — Orientation and gating

### 1.1 — The 2026 Apple AI stack, and how to choose a model backend

The map, and the decision it replaced.

**Local reference:** [part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md](part-01-orientation-and-gating/references/01-apple-ai-stack-2026-map.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| Version floor | `#version-floor` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The one thing that changed | `#1-the-one-thing-that-changed` |
| 2. The layer diagram, and what each layer owns | `#2-the-layer-diagram-and-what-each-layer-owns` |
| 3. The five `LanguageModel` conformers | `#3-the-five-languagemodel-conformers` |
| 4. Where Core ML still belongs | `#4-where-core-ml-still-belongs` |
| 5. The decision table | `#5-the-decision-table` |
| 6. The honest performance picture | `#6-the-honest-performance-picture` |
| 7. Silent failures you can hit before you write a line of model code | `#7-silent-failures-you-can-hit-before-you-write-a-line-of-model-code` |
| 8. Known-bad claims: material in circulation that is fabricated | `#8-known-bad-claims-material-in-circulation-that-is-fabricated` |
| 9. How to read this series | `#9-how-to-read-this-series` |
| 10. What this guide could not verify | `#10-what-this-guide-could-not-verify` |
| Where to go next | `#where-to-go-next` |

### 1.2 — Every version, hardware, entitlement and runtime-surface gate

The complete inventory of everything sitting between the code you write and a feature that runs: the four OS floors and what each one *means*, a per-symbol decoder ring for FoundationModels, Core AI, Evaluations, Speech and TensorOps, the SDK-versus-runtime distinction that `@available` cannot paper over, the Apple Intelligence hardware floor (A17 Pro / M1 / M2) and the **two on-device model tiers** that split by device from the fall Siri release, four first-party packages with four different version floors, the PCC entitlement and its three conditions, and the full `availability` / quota / locale runtime surface.

**Local reference:** [part-01-orientation-and-gating/references/02-platform-and-version-gating.md](part-01-orientation-and-gating/references/02-platform-and-version-gating.md)

| Section | Anchor |
|---|---|
| Contents | `#contents` |
| 1. Why four floors, not one | `#1-why-four-floors-not-one` |
| 2. The decoder ring: which API landed when | `#2-the-decoder-ring-which-api-landed-when` |
| 3. SDK gates vs runtime gates: what `@available` cannot fix | `#3-sdk-gates-vs-runtime-gates-what-available-cannot-fix` |
| 4. Hardware gates | `#4-hardware-gates` |
| 5. Xcode and toolchain gates, and the known breakages | `#5-xcode-and-toolchain-gates-and-the-known-breakages` |
| 6. Per-package requirement matrix | `#6-per-package-requirement-matrix` |
| 7. The runtime availability surface, in depth | `#7-the-runtime-availability-surface-in-depth` |
| 8. Entitlements and the business gates | `#8-entitlements-and-the-business-gates` |
| 9. App Store distribution: there is no capability flag | `#9-app-store-distribution-there-is-no-capability-flag` |
| 10. The Simulator trap, and other runtime surfaces | `#10-the-simulator-trap-and-other-runtime-surfaces` |
| 11. A runnable preflight check | `#11-a-runnable-preflight-check` |
| 12. What to test on | `#12-what-to-test-on` |
| 13. Known-bad version claims | `#13-known-bad-version-claims` |
| 14. Sources | `#14-sources` |
