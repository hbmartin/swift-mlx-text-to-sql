# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 15 — Shipping and operating on device

### 15.1 — Shipping models: Background Assets, per-architecture variants, and updates

The operational guide for how a model reaches a device and how it gets replaced later: the size problem, the feature-introduction screen (which does three jobs at once and is where you hide specialization latency), delivery, `coreai-build compile` and per-architecture `.aimodelc` variants, specialization and its cache, the update sequence, storage hygiene, app groups, and the App Store reality.

**Local reference:** [part-15-shipping-and-operating/references/01-model-distribution-and-updates.md](part-15-shipping-and-operating/references/01-model-distribution-and-updates.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Evidence markers used in this guide | `#evidence-markers-used-in-this-guide` |
| 1. The size problem | `#1-the-size-problem` |
| 2. The feature-introduction screen | `#2-the-feature-introduction-screen` |
| 3. Background Assets | `#3-background-assets` |
| 4. Per-architecture variants | `#4-per-architecture-variants` |
| 5. ⚠️ SILENT FAILURE: a green compile that the device rejects | `#5-️-silent-failure-a-green-compile-that-the-device-rejects` |
| 6. Specialization after download | `#6-specialization-after-download` |
| 7. Updating a model | `#7-updating-a-model` |
| 8. ⚠️ SILENT FAILURE: the bookmark that quietly stops working | `#8-️-silent-failure-the-bookmark-that-quietly-stops-working` |
| 9. ⚠️ SILENT FAILURE: two options structs, two multi-gigabyte specializations | `#9-️-silent-failure-two-options-structs-two-multi-gigabyte-specializations` |
| 10. App groups: sharing one specialization across targets | `#10-app-groups-sharing-one-specialization-across-targets` |
| 11. Storage hygiene | `#11-storage-hygiene` |
| 12. The App Store reality: you cannot gate installation | `#12-the-app-store-reality-you-cannot-gate-installation` |
| 13. Checklist | `#13-checklist` |
| 14. Declared gaps, collected | `#14-declared-gaps-collected` |
| Sources | `#sources` |

### 15.2 — Memory, jetsam, thermals, energy, and measuring honestly

The gap between a demo that works on your desk and an app that survives a week on someone else's phone.

**Local reference:** [part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md](part-15-shipping-and-operating/references/02-memory-thermals-and-honest-benchmarking.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| A note on evidence, before any numbers | `#a-note-on-evidence-before-any-numbers` |
| 1. The jetsam model | `#1-the-jetsam-model` |
| 2. The wrong calculation | `#2-the-wrong-calculation` |
| 3. Three real failures | `#3-three-real-failures` |
| 4. Responding to pressure | `#4-responding-to-pressure` |
| 5. MLX-specific memory | `#5-mlx-specific-memory` |
| 6. Another allocator can starve you | `#6-another-allocator-can-starve-you` |
| 7. Thermals and DVFS | `#7-thermals-and-dvfs` |
| 8. Energy | `#8-energy` |
| 9. Honest benchmarking | `#9-honest-benchmarking` |
| 10. The measurement checklist | `#10-the-measurement-checklist` |
| 11. Declared gaps | `#11-declared-gaps` |
| Where to go next | `#where-to-go-next` |
| Sources | `#sources` |
