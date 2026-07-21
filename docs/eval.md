# Evaluation method and evidence

This document explains the replacement evaluation after PR #1 and records the
completed model and temperature selection. Current score claims come only
from immutable directories under `eval/runs/`. The generated analysis
documents under `eval/analyses/` retain the exact input paths and SHA-256
hashes used for every selection.

## Run contract

One Evaluation Run is one model artifact × gold set × GCD mode × temperature
× seed cell. Its directory is never overwritten and contains:

- `manifest.json`: canonical command and run ID; Git commit/branch/dirty
  state; hardware, OS, Swift, Python, MLX, mlx-lm, xgrammar, and dependency
  versions; lockfile hashes; model/tokenizer, prompt, grammar, schema,
  database, gold-set, and artifact hashes; generation settings; and output
  hashes;
- `items.jsonl`: question, tier, generated SQL, error, failure bucket,
  entropy, token count/rate, integer-microsecond generation/execution/total
  timings, truncation, and the complete canonical typed gold and predicted
  rows up to the 10,000-row evaluation cap; and
- `summary.json`: EX, valid SQL, tier EX, p95 and mean latency, correct/wrong
  entropy means, and failure-bucket counts.

The fixed generation contract is top-p 1.0, disabled top-k, a 512-token cap,
an explicit seed, and the app’s exact prompt/schema/grammar. Python uses
`perf_counter_ns`; Swift uses `ContinuousClock`. Persisted durations are
integer microseconds, with seconds or milliseconds used only for display.

## Execution identity

Execution Accuracy is order-insensitive equality of complete typed row
multisets:

- INTEGER and REAL share a numeric domain after four-decimal, half-even
  normalization;
- TEXT remains distinct from numeric values;
- BLOB identity uses all bytes;
- NULL is its own type;
- duplicate rows and row arity matter; and
- column labels and row order do not.

A row-capped result is explicitly marked truncated and cannot compare equal to
a complete result. Canonical rows serialize to deterministic JSON; persisted
result-group IDs are SHA-256 digests. Python and Swift tests consume the same
golden fixtures.

## Statistics and deterministic rules

The matrix and rules are implemented by
`fine-tuning/eval/run_matrix.py`, `fine-tuning/eval/selection.py`, and
`fine-tuning/tools/analyze_matrix.py`.

Development comparisons use a paired item-clustered bootstrap with seed 424242
and 10,000 replicates. For configurations with repeated sampling seeds, scores
are first averaged within each gold item; item IDs—not repeated seeds—are then
sampled with replacement.

A nonzero temperature can replace temperature 0 only when mean EX improves
by at least two absolute points and the paired 95% interval excludes zero.
Eligible temperature ties resolve by valid SQL, p95 latency, then lower
temperature.

Historical across-artifact matrix analyses treat an absolute EX difference
below two points or an interval
containing zero enters the tie pool. The pool resolves by valid SQL,
worst-tier EX, p95 latency, then bundle size.

## Phase 1: four-family gold_v1 screen

All four pinned bases ran all 60 gold_v1 items at temperature 0 with GCD on
and off.

| Model | GCD | EX | Valid SQL | Tier 1 | Tier 2 | Tier 3 | p95 |
|---|:---:|---:|---:|---:|---:|---:|---:|
| Qwen2.5-Coder-3B | on | **35.00%** | **85.00%** | 70.00% | 16.67% | 20.00% | 14.803 s |
| Qwen2.5-Coder-3B | off | 33.33% | 78.33% | 70.00% | 13.33% | 20.00% | 2.806 s |
| XiYanSQL-QwenCoder-3B | off | **31.67%** | **88.33%** | 60.00% | 23.33% | 0.00% | 2.344 s |
| XiYanSQL-QwenCoder-3B | on | 26.67% | 81.67% | 55.00% | 16.67% | 0.00% | 8.286 s |
| Qwen2.5-Coder-1.5B | off | **23.33%** | **70.00%** | 60.00% | 6.67% | 0.00% | 1.367 s |
| Qwen2.5-Coder-1.5B | on | 20.00% | 53.33% | 55.00% | 3.33% | 0.00% | 6.758 s |
| Qwen3-1.7B | off | **20.00%** | 73.33% | 45.00% | 10.00% | 0.00% | 1.752 s |
| Qwen3-1.7B | on | 18.33% | **75.00%** | 45.00% | 6.67% | 0.00% | 18.552 s |

The complete analysis is
`eval/analyses/screen-c73e14c5f7b91c79/analysis.json`. It selected
Qwen2.5-Coder-3B and XiYanSQL-QwenCoder-3B by each family’s best GCD cell,
using EX, valid SQL, worst-tier EX, p95, then bundle size.

The screen also showed why GCD is not assumed beneficial. It raised
Qwen2.5-Coder-3B EX by 1.67 points but multiplied p95 latency by 5.3. It
reduced EX for the other three families and caused especially large latency
increases for Qwen3-1.7B. GCD is therefore selected separately for every
artifact.

## Phase 2: selected bases on gold_v2

The two selected bases ran all 200 gold_v2 items.

| Model | GCD | EX | Valid SQL | Tier 1 | Tier 2 | Tier 3 | p95 |
|---|:---:|---:|---:|---:|---:|---:|---:|
| Qwen2.5-Coder-3B | off | **22.00%** | **76.00%** | 38.78% | 17.29% | 11.11% | 2.782 s |
| Qwen2.5-Coder-3B | on | 15.50% | 67.50% | 28.57% | 11.28% | 11.11% | 13.265 s |
| XiYanSQL-QwenCoder-3B | off | **28.50%** | **88.00%** | 40.82% | 27.82% | 0.00% | 1.697 s |
| XiYanSQL-QwenCoder-3B | on | 27.00% | 85.00% | 38.78% | 26.32% | 0.00% | 4.114 s |

The immutable selection is
`eval/analyses/gcd-384235bf4455a900/analysis.json`; it chose GCD off for both
bases.

Failure and entropy evidence:

| Model / GCD | Execution errors | Empty | Wrong filter | Wrong join | Wrong projection | Wrong aggregation | Entropy correct / wrong |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen base / off | 48 | 16 | 40 | 37 | 8 | 7 | 0.265 / 0.353 |
| Qwen base / on | 65 | 11 | 39 | 29 | 11 | 14 | 0.311 / 0.408 |
| XiYan base / off | 24 | 22 | 57 | 21 | 7 | 12 | 0.266 / 0.300 |
| XiYan base / on | 30 | 22 | 55 | 22 | 7 | 10 | 0.274 / 0.308 |

Wrong literal/filter selection is the dominant semantic bucket for XiYan.
Qwen’s GCD-on degradation is primarily additional execution errors and
aggregation failures, despite the grammar constraint.

## Phase 3: identically trained finalists on gold_v2

The selected families received the same seed-424242, 600-iteration QLoRA
recipe and the same byte-reproduced corpus. See
`docs/training-report.md` for complete training and artifact evidence.

| Model | GCD | EX | Valid SQL | Tier 1 | Tier 2 | Tier 3 | p95 |
|---|:---:|---:|---:|---:|---:|---:|---:|
| Qwen fine-tune | on | **52.50%** | **89.50%** | 57.14% | 53.38% | 33.33% | 2.973 s |
| Qwen fine-tune | off | **52.50%** | 86.00% | 57.14% | 53.38% | 33.33% | 1.559 s |
| XiYan fine-tune | on | **65.50%** | **93.00%** | 65.31% | 69.17% | **38.89%** | 3.009 s |
| XiYan fine-tune | off | 65.00% | 92.50% | 65.31% | 69.17% | 33.33% | 1.559 s |

The complete analysis is
`eval/analyses/gcd-f929b94733b949c3/analysis.json`. It selected GCD on for
both fine-tunes: Qwen’s EX tie resolves on valid SQL, while XiYan is higher
on EX, valid SQL, and worst-tier EX.

Relative to each base family’s selected gold_v2 configuration, the Qwen
fine-tune improved EX by 30.5 points and valid SQL by 13.5 points; the XiYan
fine-tune improved EX by 37.0 points and valid SQL by 5.0 points. These are
held-out execution gains, not training-loss claims.

Failure and entropy evidence:

| Model / GCD | Execution errors | Empty | Wrong filter | Wrong join | Wrong projection | Wrong aggregation | Entropy correct / wrong |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen FT / on | 21 | 7 | 40 | 18 | 7 | 2 | 0.028 / 0.110 |
| Qwen FT / off | 28 | 6 | 40 | 15 | 4 | 2 | 0.027 / 0.108 |
| XiYan FT / on | 14 | 2 | 28 | 17 | 6 | 2 | 0.034 / 0.144 |
| XiYan FT / off | 15 | 2 | 28 | 17 | 6 | 2 | 0.032 / 0.139 |

Fine-tuning sharply separated mean entropy for correct and wrong results, but
this observation does not itself define a production threshold. Entropy
remains telemetry and a vote trigger input; accuracy and calibrated voting
determine selection.

## Phase 4: temperature standardization

Each artifact retained its deterministic GCD mode and ran all 200 gold_v2
items at temperatures 0.0, 0.1, 0.3, and 0.7 with seeds 0–4. The table reports
the five-seed, item-clustered aggregates.

| Artifact | Temperature | Mean EX | Valid SQL | Worst-tier EX | p95 | Difference from 0 / bootstrap CI |
|---|---:|---:|---:|---:|---:|---|
| Qwen base, GCD off | **0.0** | **22.00%** | **76.00%** | 11.11% | 2.842 s | baseline |
|  | 0.1 | 22.60% | 75.00% | 12.22% | 2.652 s | +0.60 [−1.10, +2.40] points |
|  | 0.3 | 24.30% | 75.90% | 10.00% | 2.347 s | +2.30 [−0.60, +5.20] points |
|  | 0.7 | 19.00% | 65.10% | 7.78% | 2.175 s | −3.00 [−7.10, +1.10] points |
| XiYan base, GCD off | **0.0** | **28.50%** | **88.00%** | 0.00% | 1.712 s | baseline |
|  | 0.1 | 28.10% | 86.70% | 0.00% | 1.719 s | −0.40 [−2.30, +1.50] points |
|  | 0.3 | 26.90% | 87.00% | 0.00% | 1.805 s | −1.60 [−4.90, +1.60] points |
|  | 0.7 | 22.00% | 78.90% | 0.00% | 1.855 s | −6.50 [−10.70, −2.30] points |
| Qwen fine-tune, GCD on | **0.0** | **52.50%** | **89.50%** | **33.33%** | 3.017 s | baseline |
|  | 0.1 | 52.10% | 89.20% | 28.89% | 2.983 s | −0.40 [−1.40, +0.30] points |
|  | 0.3 | 52.50% | 88.30% | 27.78% | 2.971 s | 0.00 [−1.60, +1.40] points |
|  | 0.7 | 52.40% | 86.90% | 24.44% | 2.976 s | −0.10 [−2.20, +2.00] points |
| XiYan fine-tune, GCD on | **0.0** | **65.50%** | **93.00%** | **38.89%** | 3.056 s | baseline |
|  | 0.1 | 66.00% | 92.70% | 38.89% | 3.072 s | +0.50 [−0.10, +1.30] points |
|  | 0.3 | 65.80% | 92.00% | 36.67% | 3.149 s | +0.30 [−1.10, +1.70] points |
|  | 0.7 | 64.70% | 90.20% | 31.11% | 3.052 s | −0.80 [−3.20, +1.60] points |

No nonzero setting satisfied both required conditions: at least a two-point
mean EX lift and a paired interval excluding zero. Temperature 0.0 therefore
remains selected for all four artifacts. The immutable analyses are:

- `eval/analyses/temperature-23f4f07cabbd4400/analysis.json`
  (Qwen base);
- `eval/analyses/temperature-46d94aff8e48f2d6/analysis.json`
  (XiYan base);
- `eval/analyses/temperature-139fa44908f7b7df/analysis.json`
  (Qwen fine-tune); and
- `eval/analyses/temperature-2d63595b7361e9d3/analysis.json`
  (XiYan fine-tune).

The temperature experiments also show why a single hardcoded sampling value
is not acceptable. The best-looking nonzero point estimate—the Qwen base at
0.3—reached the two-point magnitude requirement but its interval crossed
zero. The hottest settings reduced valid SQL by 9.1 points for the XiYan base
and 2.8 points for the XiYan fine-tune.

## Phase 5: production artifact selection

`eval/analyses/production-cddac7c992c20eae/analysis.json` compared exactly
one eligible five-seed configuration for each artifact.

| Rank | Artifact / configuration | EX | Valid SQL | Worst-tier EX | p95 |
|---:|---|---:|---:|---:|---:|
| 1 | **XiYan fine-tune, GCD on, temperature 0** | **65.50%** | **93.00%** | **38.89%** | 3.056 s |
| 2 | Qwen fine-tune, GCD on, temperature 0 | 52.50% | 89.50% | 33.33% | 3.017 s |
| 3 | XiYan base, GCD off, temperature 0 | 28.50% | 88.00% | 0.00% | 1.712 s |
| 4 | Qwen base, GCD off, temperature 0 | 22.00% | 76.00% | 11.11% | 2.842 s |

The XiYan fine-tune is the sole member of the production tie pool. Against
the Qwen fine-tune its EX advantage is 13.0 points with a paired 95% interval
of [6.5, 19.5] points. Its advantages over the XiYan and Qwen bases are 37.0
[28.5, 45.5] and 43.5 [34.5, 52.5] points respectively. No tie-break was
needed.

The selected artifact is the public, fresh-download-verified
`hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit`
snapshot at revision `7f97a54819b9329338a5353266d6d2a1294eb341`.

## Phase 6: N=3 always-vote calibration

`eval/analyses/consistency-926c85c7ebc25eae/analysis.json` calibrated one
deterministic temperature-zero anchor plus two independently seeded samples
on every gold_v2 item, repeated for trial seeds 0–4. Each temperature
therefore represents 1,000 item-trials and 3,000 Candidate Queries.

| Sample temperature | EX | Valid SQL | Consensus | No Consensus | Anchor failures | Mean / p95 latency |
|---:|---:|---:|---:|---:|---:|---:|
| 0.1 | 65.60% | 93.60% | 931 | 2 | 70 | 6.614 / 9.178 s |
| 0.3 | 65.80% | 93.80% | 920 | 13 | 70 | 6.626 / 9.441 s |
| **0.7** | **66.80%** | **95.40%** | 893 | 40 | 70 | 6.643 / 9.158 s |

Temperature 0.7 produced the highest EX and valid-SQL rates and is selected
for the two consistency samples. This does not replace the production
candidate's deterministic temperature 0.0: it configures only the two sample
roles in the calibrated three-candidate portfolio.

The 70 anchor failures are 14 deterministic-anchor item failures repeated
over five trial seeds, not 70 distinct questions. Failed candidates remain
in the strict-majority denominator. No Consensus selects the complete
deterministic anchor with a visible notice; a failed or truncated anchor
uses only the separately labeled degraded fallback.

These numbers come from the schema_version 1 calibration harness. The
harness was subsequently revised to mirror production exactly — empty
results no longer vote, eligibility applies the production 500-row cap, and
an anchor failure delivers the anchor's own degraded outcome instead of a
substituted sample (see `docs/self-consistency-report.md`). The table
remains the immutable evidence behind the historical 0.7 selection; a
schema-version-3 bounded-policy recalibration is required before quoting it as a production-faithful
expectation.

## Phase 7: full Python/Swift parity

The selected single-shot configuration ran all 200 gold_v2 items in both
harnesses. The final gate is
`eval/analyses/parity-cda177e757fbb0b6/analysis.json`.

| Harness | EX | Valid SQL | SQLite |
|---|---:|---:|---|
| Python / MLX | 65.50% | 93.00% | 3.53.3 |
| Swift / MLX Swift | 65.00% | 92.00% | 3.43.2 |
| Absolute delta | **0.50 points** | **1.00 point** | — |

Both deltas are within the two-point gate. The analyzer found 14 item-level
differences and accepted the run only after every one received a persisted
explanation:

- nine formatting/tokenization differences produced identical complete typed
  Result Group digests;
- two outputs were invalid in both runtimes;
- one item was valid only in Python, but both answers were EX-incorrect;
- one item produced different valid, EX-incorrect result groups; and
- one identical SQL statement (`T3-49`) changed validity because Python used
  SQLite 3.53.3 while the Swift host used system SQLite 3.43.2.

The detailed item ledger is in `docs/parity-report.md`; machine-readable SQL,
errors, digests, and explanations remain in the parity analysis. The gate
records `metrics_pass: true`, `all_disagreements_explained: true`, and
`pass: true`.

## Verified production configuration

After publication, calibration, and parity passed, the fail-closed
finalization tool set `model-manifest.json` to `production_status: verified`.
The manifest SHA-256 at finalization was
`be2bc2ff256577e72173bd1bf52422c4a38650c0b91101c3c971e9b53f3d7b73`.
Production is the public XiYan fine-tune at revision `7f97a548…`, GCD on,
temperature 0.0, top-p 1.0, top-k disabled, 512 tokens, and N=3 always-vote
with two temperature-0.7 samples.

## Legacy PR #1 results — incomplete provenance

The former `eval/out` files are preserved in
`eval/runs/legacy-pr1-merged/`. Their manifest identifies the unavailable
fine-tuned artifact, missing complete training configuration/seed provenance,
and other gaps. They may explain historical decisions but must not be used to
reproduce or advertise the current production artifact.
