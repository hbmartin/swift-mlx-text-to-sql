# CREG

CREG is an iOS text-to-SQL research prototype for a fixed, synthetic
commercial-real-estate portfolio. It rewrites and gates a question on device,
generates SQL with a pinned 4-bit MLX model, executes against a bundled
read-only SQLite database, and returns a table plus a concise narration.

The product requirements are in
[`CREG — Product Requirements Document.md`](./CREG%20—%20Product%20Requirements%20Document.md),
the domain language is in [`CONTEXT.md`](./CONTEXT.md), and decisions are in
[`docs/adr/`](./docs/adr/).

## Reliability-v2 status

The checked-in manifest still records the historical production artifact, the public
[XiYanSQL-QwenCoder-3B CREG fine-tune](https://huggingface.co/hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit/tree/7f97a54819b9329338a5353266d6d2a1294eb341)
at immutable revision `7f97a54819b9329338a5353266d6d2a1294eb341`.
Its evidence predates the bounded three-generation policy and is retained only
as immutable historical evidence. A Release build now refuses that manifest
until fresh reliability-v2 training, schema-v3 calibration, parity,
publication, bundle, device, and complete W&B receipts pass finalization.

| Historical check | Result |
|---|---|
| Python single-shot, 200 gold_v2 items | 65.50% EX; 93.00% valid SQL |
| Swift single-shot, same 200 items | 65.00% EX; 92.00% valid SQL |
| Python/Swift absolute drift | 0.50 EX points; 1.00 valid-SQL point; pass |
| N=3 always-vote, 1,000 item-trials | 66.80% EX; 95.40% valid SQL |
| Pre-remediation unit suites | 66 Python and 30 Swift tests passed |

The reliability-v2 runtime validates every generated statement with SQLite
before execution and caps SQL generation at three calls. A valid initial
candidate receives two independently seeded temperature-0.7 cross-checks; a
repairable invalid candidate receives one deterministic and one sampled
repair. Two matching non-empty result digests confirm an answer. Otherwise a
valid deterministic repair, sampled repair, or initial anchor is shown as
unconfirmed; no generated SQL is rewritten in code.

The merged PR #1 outputs remain under
[`eval/runs/legacy-pr1-merged`](./eval/runs/legacy-pr1-merged) and are marked
`incomplete-provenance`. The original fine-tuned artifact, seed, and complete
training configuration were unavailable, so those historical scores are not
current evidence.

Detailed reports:

- [final report](./docs/final-report.md)
- [evaluation and statistical method](./docs/eval.md)
- [training and publication](./docs/training-report.md)
- [self-consistency calibration](./docs/self-consistency-report.md)
- [full Python/Swift parity](./docs/parity-report.md)
- [implementation and release verification](./docs/verification-report.md)
- [license and distribution](./docs/license-report.md)

## Architecture

Each turn is sequential so Apple Foundation Models and MLX inference never
overlap:

```text
question
  → standalone-question rewrite
  → ambiguity gate
  → identified SQL candidate generation
  → read-only SQLite prepare/validation
  → execute valid candidates only
  → bounded repair or cross-check generation
  → non-empty result consensus and confidence
  → column-aware grounding checks
  → narration and rendering
```

Every candidate retains its ID, role, model/revision, GCD mode, temperature,
seed, SQL, token metrics, integer-microsecond timings, complete typed result
rows, truncation, errors, Result Group SHA-256, and selection state.
`TurnTelemetry` is the immutable record rendered by developer mode and
persisted in chat history and JSONL.

Python EX, Swift EX, and voting share one result identity:

- INTEGER and REAL share a numeric domain after four-decimal, half-even
  normalization;
- TEXT, full BLOB bytes, and NULL remain distinct;
- duplicate rows and row arity matter, while row order and labels do not; and
- truncated rows are explicitly incomplete and cannot join a Result Group.

Grounding is column-aware. Only unambiguously resolved entity/categorical
columns in supported `=` and `IN` predicates are checked. Failed or partial
catalog loads are never cached; the valid query result remains available,
the exact degradation is recorded, unsupported notices are suppressed, and
a later turn retries.

## Repository layout

```text
CREG.xcodeproj/                 iOS application
CREG/                           app entry point and assets
CREGKit/
  Sources/CREGEngine/           generation, execution, grounding, voting
  Sources/CREGFeatures/         chat, history, telemetry UI
  Sources/creg-eval-cli/        production-stack full-gold parity CLI
  Tests/CREGKitTests/           runtime and persistence tests
db/                             frozen schema and synthetic SQLite portfolio
eval/gold/                      held-out gold_v1 and gold_v2
eval/runs/                      immutable evaluation artifacts
eval/analyses/                  content-addressed selection/calibration/parity
eval/training-runs/             immutable QLoRA provenance
eval/publications/              public-snapshot verification records
fine-tuning/
  config/                       complete QLoRA and conversion configuration
  eval/                         typed EX, run writer, matrix, statistics
  synth/                        deterministic corpus generation
  tools/                        acquisition, training, publication, inspection
model-manifest.json             pinned candidates and production configuration
```

## Prerequisites

- macOS 15 or newer for host tests.
- Xcode 26.3 and Swift 6.2.4.
- An iOS 26 Apple Intelligence-capable device for the complete app flow.
- [`uv`](https://docs.astral.sh/uv/) on Xcode's `PATH`, or installed at
  `~/.local/bin/uv`.
- Network access and several gigabytes of free disk for a clean Release build.
- Hugging Face authentication only for publication or access-controlled
  acquisition; credentials must never be committed.

Python commands use the committed `uv.lock`. Do not substitute bare `python`
or an independently resolved environment.

The project pins mlx-swift exactly to 0.31.4 and mlx-swift-lm exactly to
3.31.4.

## Acquire model artifacts

The manifest pins four upstream sources, explicit XiYan bfloat16-to-MLX
4-bit/group-64/affine conversion, both public fine-tunes, every expected
file, size, SHA-256, directory digest, and license payload. Floating revisions
are rejected. Weights stay outside Git in the Hugging Face cache and ignored
`models/` materialization.

```sh
cd fine-tuning

# Every declared source and derived artifact
uv run --frozen python tools/fetch_model.py --all
uv run --frozen python tools/fetch_model.py --all --verify-only

# One artifact
uv run --frozen python tools/fetch_model.py \
  --model ft-xiyansql-qwencoder-3b

# Exact verified production snapshot
uv run --frozen python tools/fetch_model.py --production
```

## Build behavior

The Xcode build phase runs the model materializer through the frozen `uv`
environment and writes the exact bundled manifest into the app.

- Debug defaults `CREG_DEBUG_TRAINING_RUN` to `latest-local-v3`. It selects the
  newest locally eligible reliability-v3 run, verifies finite training,
  three-snapshot checkpoint selection, the selected adapter hash, and the
  manifest-pinned base bytes, then fuses and bundles that checkpoint. This
  developer path intentionally does not require a W&B receipt. Its generated
  manifest is marked `debug-candidate`, uses deterministic single-shot
  generation, and displays a permanent experimental-model banner. Set the
  build setting to an immutable run ID/path to pin a particular run, or set it
  to an empty value to use the historical manifest-selected Debug model.
- Release requires a newly finalized bounded-policy selection, downloads or
  reuses cache, transactionally verifies the complete snapshot, and bundles
  it as `SQLModel` with `production-model-receipt.json`. Historical policy,
  Debug candidate override, network, selection, receipt, or integrity failure
  stops the build. Neither configuration has a runtime Hub fallback.

```sh
xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Debug -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build

# Pin one immutable local run instead of selecting the newest eligible run.
xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Debug -destination 'generic/platform=iOS' \
  CREG_DEBUG_TRAINING_RUN='<run-id-or-directory>' build

xcodebuild -project CREG.xcodeproj -scheme CREG \
  -configuration Release -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Inspect a Release bundle byte-for-byte:

```sh
cd fine-tuning
uv run --frozen python -m tools.inspect_release_bundle \
  --app /path/to/Build/Products/Release-iphoneos/CREG.app \
  --run-id release-bundle-inspection
```

The inspector rejects a different manifest or receipt, symlinks and special
entries, missing/extra/mismatched model files, or missing license/notice.

## Tests

```sh
cd fine-tuning
uv run --frozen pytest

cd ../CREGKit
swift test
```

Coverage includes typed EX and shared golden fixtures, half-even rounding,
full BLOB identity, duplicates, truncation, immutable runs and seed replay,
manifest integrity, bounded three-generation consensus and fallback behavior,
validation, repairs and candidate attribution, telemetry migration,
microsecond timing, alias-aware grounding, retryable catalogs, empty-string
edit distance, and read-only database enforcement.

## Reproduce training and evaluation

Every evaluation command creates a new non-overwriting directory with
`manifest.json`, `items.jsonl`, and `summary.json`.

```sh
cd fine-tuning

# Four bases × gold_v1 × GCD on/off
uv run --frozen python -m eval.run_matrix screen

# Selected bases × all gold_v2 × GCD on/off
uv run --frozen python -m eval.run_matrix gcd \
  --artifact qwen25-coder-3b:on \
  --artifact qwen25-coder-3b:off \
  --artifact xiyansql-qwencoder-3b:on \
  --artifact xiyansql-qwencoder-3b:off

# Byte-reproduce the corpus, run the authenticated smoke, then create the two
# independent reliability-v2 18-run screening sweeps. (`direnv allow` loads
# WANDB_ENTITY and WANDB_PROJECT from a local, Git-ignored .envrc; keep the API
# key outside the repository.)
export WANDB_API_KEY=...
uv run --frozen python -m tools.run_experiment \
  --model-key qwen25-coder-3b \
  --campaign-id creg-sql-reliability-v2-smoke --iterations 100
uv run --frozen wandb sweep --entity "$WANDB_ENTITY" \
  --project "${WANDB_PROJECT:-creg-sql}" \
  config/sweeps/qwen25-coder-3b.yaml
uv run --frozen wandb sweep --entity "$WANDB_ENTITY" \
  --project "${WANDB_PROJECT:-creg-sql}" \
  config/sweeps/xiyansql-qwencoder-3b.yaml
```

After 36 screening runs, promote the top two recipes per family over seeds
424240/424241/424242, reusing each screening seed-424242 result. This creates
eight new confirmation runs (44 training runs total). Winner selection uses
gold-v1 item-clustered EX, valid SQL, worst-tier EX, p95 latency, and trainable
parameter count. See `fine-tuning/README.md` for the exact promotion, final
evidence, binding-regression, and production-finalization commands.

Publication is explicit and records the returned Hub commit plus a forced
fresh-download inventory verification:

```sh
uv run --frozen python -m tools.publish_finalists \
  --training-run ../eval/training-runs/<first> \
  --training-run ../eval/training-runs/<second> \
  --result-run ../eval/runs/<first-result> \
  --result-run ../eval/runs/<second-result>
```

## Full Swift parity

Build the host CLI through Xcode Release so the MLX Metal library is present;
direct `swift run` is not a valid parity invocation.

```sh
xcodebuild -scheme creg-eval-cli -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/creg-parity-derived \
  -skipPackagePluginValidation -skipMacroValidation build

/tmp/creg-parity-derived/Build/Products/Release/creg-eval-cli \
  --model models/creg-sql-xiyansql-qwencoder-3b-mlx-4bit \
  --model-key ft-xiyansql-qwencoder-3b \
  --repository hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit \
  --revision 7f97a54819b9329338a5353266d6d2a1294eb341 \
  --db db/creg.sqlite --gold eval/gold/gold_v2.jsonl \
  --gcd on --temperature 0.0 --seed 0 \
  --out eval/runs/<new-parity-run>/swift.json
```

Then run `tools.analyze_matrix parity` with an immutable matching Python run
and persist explanations for every item difference. Both absolute metric
deltas must be at most two points.

## Licenses, privacy, and limitations

The selected XiYan derivative carries both its Apache-2.0 text and the
conservatively inherited Qwen Research License, plus attribution, modification
notice, “Built/Improved using Qwen,” and a non-commercial-use warning. CREG is
therefore a **non-commercial research prototype**. See
[`docs/license-report.md`](./docs/license-report.md); it is an engineering
record, not legal advice.

The database is synthetic, but telemetry exports contain portfolio questions,
generated SQL, errors, seeds, and complete result rows up to the applicable
cap (500 app, 10,000 evaluation). Treat exports as portfolio data.

CREG supports one frozen schema and read-only exploration. It is not suitable
for arbitrary databases, write queries, production financial decisions, or
unreviewed model/runtime upgrades. Genuine remaining work includes physical
iOS-device memory/thermal/latency validation, broader novel-language coverage
to reduce template overfitting, and eliminating SQLite-version-sensitive SQL.
