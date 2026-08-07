# TestFlight release

CREG ships to TestFlight from the **Beta** build configuration, not Release.
This document records why, how to produce the archive, and what App Store
Connect needs.

## Why Beta exists

Release refuses to build. The materializer runs
`fetch_model.py --production` without `--allow-historical-policy`, and
`model-manifest.json` carries no `production.policy_version`, so acquisition
raises before a bundle is produced. Even bypassed, `LiveDependencies.pipeline`
requires `policy_version == "bounded-three-generation-v1"` in non-Debug builds
and would boot to `.unavailable`.

Clearing that gate legitimately is a full campaign, not a manifest edit.
`tools.finalize_production` requires a gold-v1 campaign winner, a locked
gold-v2 evaluation, binding regressions, bounded-policy calibration, full
Python/Swift parity, and a fresh-verified public publication with a complete
W&B receipt. None exist yet, and the current candidate does not clear the
`MINIMUM_PRODUCTION_EX` floor of 66.8% (it scores 63.33% EX on gold_v1).

Beta therefore bundles the **pinned experimental candidate** through the same
Debug materialization path — real manifest, real content-addressed receipt,
full byte verification at startup — and labels it in the UI. It is
`production_status: "debug-candidate"`, and it is not production finalized.

**Beta is not a relaxation of Release.** Release stays strict and unchanged.
When a campaign finally clears finalization, retire Beta rather than promoting
it.

### What Beta changes

| | Debug | Beta | Release |
|---|---|---|---|
| Optimization | `-Onone` | `-O`, whole-module | `-O`, whole-module |
| Model source | newest local v3 run | **pinned** run ID | manifest production selection |
| Debug candidates | allowed | allowed | refused |
| Bounded-policy check | skipped | skipped | **required** |
| Receipt verification | required | **required** | required |
| `CREG_BENCHMARK_QUESTION` | honored | **ignored** | ignored |
| `CREG_WIRED_MEMORY` | honored | **ignored** | ignored |
| Experimental banner | shown | **shown** | n/a |

The Swift condition is `CREG_EXPERIMENTAL_MODEL`, set in the **project-level**
Beta configuration. It must stay at project level: local SPM package targets
(`CREGEngine`, `CREGFeatures`) inherit project-level build settings, and a
target-level condition never reaches them.

## The pinned model

`CREG_EXPERIMENTAL_TRAINING_RUN` in the Beta target configuration pins:

```
qwen25-coder-3b-73cb7525c61bc76c76d880076d56d39e0f25cd1675f21a01c28ae2b560838500-seed-424242-wb-0qvg7e4k
```

iteration 600, 63.33% EX on gold_v1.

Debug uses `latest-local-v3`, which resolves by `max(started_at, run_id)` and
would silently change what ships when a new local run finishes. Beta pins an
immutable run ID instead. To move Beta to a different checkpoint, change that
build setting deliberately.

The script refuses `CREG_EXPERIMENTAL_TRAINING_RUN` outside Beta, mirroring the
existing `CREG_DEBUG_TRAINING_RUN` guard.

### Reproducibility caveat

The Beta build materializes from `models/adapters/` and `models/debug-fused/`,
both gitignored and present only on the machine that trained the run. **CI
cannot build a Beta archive.** Produce it locally, and keep those directories
until a finalized production model replaces this path.

## Producing the archive

Xcode's Product ▸ Archive uses Beta — the shared `CREG` scheme's archive action
points at it. From the command line:

```sh
xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Beta -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -archivePath build/install/CREG-beta.xcarchive archive
```

Export for upload with `method: app-store-connect` (the checked-in
`build/install/ExportOptions.plist` is a `debugging` export and must not be
reused for TestFlight):

```sh
xcodebuild -exportArchive \
  -archivePath build/install/CREG-beta.xcarchive \
  -exportPath build/install/beta-export \
  -exportOptionsPlist <app-store-connect-options>.plist
```

A strict Release build is still available, and should still fail:

```sh
xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Release -destination 'generic/platform=iOS' build
```

## Build numbers

`CFBundleVersion` is stamped by the **Stamp Distribution Build Number** phase
as a UTC `YYYYMMDDHHMM` value, matching the convention recorded in earlier
install notes (for example `202607291033`). App Store Connect rejects a
repeated build number, so every archive gets a fresh one automatically. Debug
keeps `$(CURRENT_PROJECT_VERSION)` so incremental builds do not churn.

`CFBundleShortVersionString` comes from `MARKETING_VERSION` and is bumped by
hand.

## Device floor

`DeviceCapability` enforces **iPhone 15 or newer**. Below the floor, `RootView`
renders `UnsupportedDeviceView` and never constructs the store, so the ~1.75 GB
model is never loaded; `LiveDependencies.pipeline` carries a second guard for
any future entry point that bypasses the wall.

The identifier boundary is not intuitive — `iPhone15,2` and `iPhone15,3` are
the iPhone 14 Pro and 14 Pro Max, while `iPhone15,4` is the iPhone 15. The rule
is `major > 15 || (major == 15 && minor >= 4)`.

Debug builds bypass the floor so the simulator, previews, and development on
older hardware still work. To exercise the wall, run a simulator with
`SIMULATOR_MODEL_IDENTIFIER` set to an unsupported identifier.

TestFlight cannot enforce a hardware floor at install time, so this runtime
gate and the tester notes are the only enforcement.

## App Store Connect checklist

Export compliance is answered in the bundle
(`ITSAppUsesNonExemptEncryption = false`) — CREG has no runtime networking and
uses swift-crypto only for hashing — so uploads do not prompt per build.

- **App Privacy**: *Data Not Collected*. Everything stays on device; a Support
  Bundle leaves only when the user explicitly emails or shares it.
- **Beta App Description**: state that this is a non-commercial research
  prototype over a fixed synthetic commercial-real-estate portfolio.
- **What to Test**: free-form portfolio questions and the five starter queries;
  Helpful / Not right feedback; the Support Bundle export.
- **Minimum device**: iPhone 15 or newer, iOS 26. Say so explicitly — testers
  on older hardware see only the unsupported-device screen.
- **Experimental model**: disclose that the bundled SQL model is an unfinalized
  candidate, that the in-app banner is expected, and that answers can be wrong.
- **As-of date**: answers about "now" reflect the fixed 2026-07-01 portfolio
  snapshot, not today's date.
- **App icon**: three Icon Composer documents live in `CREG/` and are generated
  by `tools/make_app_icons.py`. `AppIconMidnight` is primary; the other two ship
  as alternates the user picks in Settings. actool renders every required size
  including the opaque 1024pt marketing asset, so there is no PNG to hand-check.

## Still open

- Release remains unbuildable until a campaign clears the 66.8% EX floor.
- Distribution signing and the App Store Connect app record are not yet set up;
  the only archive produced so far was Development-signed.
