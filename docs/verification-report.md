# Implementation and release verification report

Status: **all blocking checks pass**.

This report covers runtime correctness, tests, model identity, parity, and
build packaging for the PR #1 follow-up. Model-quality evidence is in
`docs/eval.md`, training evidence in `docs/training-report.md`, and license
enforcement in `docs/license-report.md`.

## Test suites

Python:

```sh
cd fine-tuning
uv run --frozen pytest
```

Result: **62 passed** on Python 3.14.6 through the committed `uv.lock`.

Swift:

```sh
cd CREGKit
swift test
```

Result: **42 passed** in eight suites on Swift 6.2.4.

The combined suites verify:

- INTEGER/REAL equivalence after four-decimal half-even normalization;
- TEXT/numeric separation, full BLOB bytes, NULL, duplicate rows, row arity,
  order independence, truncation, and shared Python/Swift fixtures;
- immutable run creation, output hashes, exact-compatible run reuse, seed
  replay, and manifest integrity;
- strict majority, all-unique No Consensus, deterministic fallback, failed
  and truncated-anchor degradation, and repair attribution;
- candidate IDs/roles/model revisions/GCD/temperature/seeds, full rows,
  errors, selection state, token metrics, and integer-microsecond durations;
- first-turn standalone reporting, immutable telemetry persistence, and
  schema-versioned old-history decoding;
- column/alias grounding, categorical `Active`, same-column misspelling
  suggestions, unsupported predicate skips, failed/partial catalog retry, and
  empty-left/right/both edit distance;
- prompt/schema/grammar identity and read-only database authorization;
- complete QLoRA defaults, byte-reproduced corpus, gold_v2 holdout, model
  inventory, publication card/license/notice requirements; and
- paired item-clustered bootstrap temperature and production selection.

The parity analyzer additionally rejects drift in model key/repository/
revision, GCD, temperature, run and item seeds, tier, gold SQL, database,
gold, model, grammar, prompt, package locks, top-p, top-k, token cap, row cap,
or canonical gold digest before explanations are considered.

## Model, training, and publication

All four upstream revisions and the explicit XiYan conversion reverified from
the manifest. Both QLoRA jobs regenerated the corpus byte-for-byte and used
the same seed-424242, 600-iteration, batch-4, 16-layer, `1e-4` configuration.
Both fused artifacts retained affine 4-bit/group-64 quantization and passed
`mlx_lm.load`.

Both finalists were published publicly and independently fresh-downloaded:

| Artifact | Public revision | Fresh tree | Result |
|---|---|---|---|
| Qwen fine-tune | `430d38301eedb6c61e48c25c7d38a2b227bf56c6` | `c09f7ec567a5d45dbbb3fbbd35b1e9db6933b6db5bf0e6ab1fd772af275c5204` | Pass |
| XiYan fine-tune | `7f97a54819b9329338a5353266d6d2a1294eb341` | `a3befce92b39afe29c0c0b01c534bd81731f151940470697d5f2038c89efd8c6` | Pass |

The model cards include base/data/code identities, complete YAML, hashes,
evaluation evidence, limitations, modification notice, attribution, and the
non-commercial warning. The winning XiYan snapshot has 12 declared files,
including `LICENSE`, `QWEN_LICENSE`, and `NOTICE`.

## Evaluation gates

The complete 80-cell temperature matrix retained deterministic temperature
0.0 for all four eligible artifacts. Production analysis selected the public
XiYan fine-tune at 65.50% EX, 93.00% valid SQL, and 38.89% worst-tier EX.
Its +13.0-point EX advantage over the Qwen fine-tune has a paired 95%
interval of [+6.5, +19.5].

N=3 calibration selected two temperature-0.7 samples around the deterministic
anchor. Across 1,000 item-trials it reached 66.80% EX and 95.40% valid SQL,
with 893 consensus outcomes, 40 No Consensus outcomes, and 70 anchor-failure
trial instances.

Full parity compared all 200 items:

| Harness | EX | Valid SQL |
|---|---:|---:|
| Python | 65.50% | 93.00% |
| Swift | 65.00% | 92.00% |
| Absolute delta | **0.50 points** | **1.00 point** |

Both deltas are below the two-point limit. All 14 differing items have
persisted explanations. The final gate at
`eval/analyses/parity-cda177e757fbb0b6/analysis.json` records
`metrics_pass: true`, `all_disagreements_explained: true`, and `pass: true`.
See `docs/parity-report.md`.

The production finalizer then wrote manifest SHA-256
`be2bc2ff256577e72173bd1bf52422c4a38650c0b91101c3c971e9b53f3d7b73`
with:

- model `ft-xiyansql-qwencoder-3b` at public revision `7f97a548…`;
- GCD on, temperature 0.0, top-p 1.0, top-k disabled, 512 tokens; and
- N=3 always-vote with sample temperature 0.7.

## Clean-cache Debug build

An isolated generic-iOS Debug build used new `CREG_MODELS_DIR`, `HF_HOME`,
and DerivedData paths. No production model existed in either cache.

Result:

- Xcode build succeeded;
- the embedded manifest SHA-256 exactly matched the source manifest;
- no `SQLModel` was bundled;
- the isolated model cache remained empty; and
- the build emitted the documented first-use pinned-download warning.

The record is
`eval/build-verification/debug-no-cache-20260721/report.json`. This confirms
Debug does not silently download 1.7 GB during the build when no cache exists.

## Clean-cache Release build and inspection

A separate generic-iOS Release build used empty model/Hugging Face caches and
separate DerivedData. The build fetched all 12 files from the exact public
revision, verified them, and bundled `SQLModel`.

The independent inspector produced
`eval/build-verification/release-xiyansql-qwencoder-3b-7f97a548/report.json`
with `status: complete`:

| Inspection | Expected | Observed | Result |
|---|---|---|---|
| Embedded manifest SHA-256 | `be2bc2…7b73` | `be2bc2…7b73` | Pass |
| Model revision | `7f97a548…b341` | `7f97a548…b341` | Pass |
| Required files | 12 | 12 | Pass |
| Model tree SHA-256 | `a3befc…8c6` | `a3befc…8c6` | Pass |
| Bundle model bytes | 1,747,812,702 | 1,747,812,702 | Pass |
| Extra files | none | none | Pass |
| License and notice payload | required | present and hash-matched | Pass |

The Xcode project has no static `models/SQLModel` reference. Its always-run
phase locates `uv`, uses `uv run --frozen`, copies the manifest, and makes
Debug cache-only versus Release verified-download behavior explicit.

Two hardening changes postdate the archived report above. The inspector now
scans every real file in the bundled `SQLModel` tree — including `.cache/`
paths and the fetch-time artifact lock, which its inventory helper
previously skipped — when detecting unexpected extras, and materialization
no longer copies `.creg-artifact.json` into the bundle. The archived
Release bundle contains that lock file, so re-inspecting it with the
current inspector reports one unsupported extra; bundles built from this
revision onward contain exactly the manifest tree plus license files.

## Host parity build note

A direct `swift run creg-eval-cli` host invocation failed because SwiftPM did
not package MLX's default Metal library. The canonical parity CLI was therefore
built with:

```sh
xcodebuild -scheme creg-eval-cli -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /Volumes/SanSmall/creg-parity-release-derived \
  -skipPackagePluginValidation -skipMacroValidation build
```

This is a build-environment constraint, not a waived parity result: the
Xcode-built Release CLI completed all 200 items and supplied the passing
evidence above.

## Completion assessment

No legacy PR #1 score is used as reproducible evidence. Every current score
traces to immutable run manifests and generated analyses; both published
fine-tunes have fresh-download evidence; the selected configuration passes
full Swift parity; and Release packaging contains the exact selected bytes
and required legal payload.
