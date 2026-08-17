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

Beta therefore uses the same model selection and runtime policy as Debug. By
default it resolves the newest eligible local reliability-v3 candidate, but it
can also select an explicit local run or fall back to the verified production
selection. Candidate builds use a real manifest and content-addressed receipt
and remain clearly labeled as experimental.

**Beta is not a relaxation of Release.** Release stays strict and unchanged.
When a campaign finally clears finalization, retire Beta rather than promoting
it.

### What Beta changes

| | Debug | Beta | Release |
|---|---|---|---|
| Optimization | `-Onone` | `-O`, whole-module | `-O`, whole-module |
| Model source | candidate selector or verified production | candidate selector or verified production | manifest production selection |
| Debug candidates | allowed | allowed | refused |
| Bounded-policy check | skipped | skipped | **required** |
| Receipt verification | required | **required** | required |
| `CREG_BENCHMARK_QUESTION` | honored | **ignored** | ignored |
| `CREG_WIRED_MEMORY` | honored | **ignored** | ignored |
| Experimental banner | shown | **shown** | n/a |

The app writes `CREGBuildChannel=beta` into its processed Info.plist. Runtime
policy reads that value explicitly. Do not use an app-project Swift compilation
condition for this decision: local Swift-package targets compile with their own
Release configuration and do not inherit `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
from the app project.

## Shared candidate selection

`CREG_CANDIDATE_TRAINING_RUN` defaults to `latest-local-v3` in both Debug and
Beta. That selector resolves by `max(started_at, run_id)`. Set it to an explicit
run ID to make a local build immutable, or clear it to bundle the verified
production selection. Release does not define the setting and rejects any
candidate selector.

Every manifest is stamped with runtime-contract version 1, the full Git source
revision, and the source dirty flag. The processed Info.plist receives matching
values. Startup fails closed if the compiled contract, manifest, and Info.plist
do not agree. The TestFlight publisher additionally refuses dirty provenance.

### Reproducibility caveat

The Beta build materializes from `models/adapters/` and `models/debug-fused/`,
both gitignored and present only on the machine that trained the run. **CI
cannot build a Beta archive.** Produce it locally, and keep those directories
until a finalized production model replaces this path.

## Producing the archive

Use the checked-in publisher for TestFlight. Each attempt places DerivedData
under its own attempt directory so local Release package products cannot leak
into a Beta archive. Candidate preflight resolves and validates the exact local
run, then pins that run ID into the archive command so a concurrently completed
training run cannot change what the attempt ships:

```sh
python3 .agents/skills/publish-creg-testflight/scripts/publish_testflight.py preflight
python3 .agents/skills/publish-creg-testflight/scripts/publish_testflight.py publish
```

The publisher verifies both the archive and exported IPA before upload. It
validates each app's code signature independently and compares executable bytes
after removing only the embedded signature, allowing the normal App Store
export re-signing step without weakening executable identity. For
manual inspection of already-produced artifacts, pass the clean preflight Git
revision. The gate checks bundle/version/build identity, runtime contract,
provenance, executable identity, complete candidate and selected-model identity,
manifest/receipt hashes, SQLModel inventory, and Metal library:

```sh
cd fine-tuning
uv run --frozen python tools/inspect_release_bundle.py \
  --configuration Beta \
  --run-id beta-<UTC timestamp> \
  --expected-source-revision <40-character-Git-SHA> \
  --expected-training-run <preflight-training-run-id> \
  --archive ../build/install/CREG-beta.xcarchive \
  --ipa ../build/install/beta-export/CREG.ipa
```

Do not upload when this command fails or when its report does not contain two
complete artifacts (`archive` and `ipa`). On-device startup intentionally keeps
the lightweight manifest/receipt identity check and does not re-hash the 1.65
GB model; the archive/export gate is the full-byte integrity boundary.

A strict Release build is still available, and should still fail:

```sh
xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Release -destination 'generic/platform=iOS' build
```

## Build numbers

`CFBundleVersion` is stamped by the **Stamp Distribution Build Number** phase
as a UTC `YYYYMMDDHHMMSS` value; seconds precision keeps back-to-back archives
from ever sharing a build number. (Earlier install notes recorded the
minute-precision predecessor, for example `202607291033`.) App Store Connect
rejects a repeated build number, so every archive gets a fresh one
automatically. Debug keeps `$(CURRENT_PROJECT_VERSION)` so incremental builds
do not churn.

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
- **Artifact gate**: retain the complete schema-v3 verification report for both
  the `.xcarchive` and exported `.ipa`; no successful report means no upload.

## Still open

- Release remains unbuildable until a campaign clears the 66.8% EX floor.
- Distribution signing and the App Store Connect app record are not yet set up;
  the only archive produced so far was Development-signed.
