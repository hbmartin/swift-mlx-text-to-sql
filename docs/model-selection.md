# Model selection

Model selection is a sequence of immutable evidence gates, not a hand-picked
score. The source of truth is `model-manifest.json`; its production entry is
written only after publication, temperature standardization, cross-artifact
statistics, self-consistency calibration, full Python/Swift parity, and bundle
inspection pass.

## Fixed decision rules

1. Screen all four bases on gold_v1 at temperature 0 with GCD on/off.
2. Within each family choose the GCD cell by EX, valid SQL, worst-tier EX, p95
   latency, then bundle size. Advance the top two families by the same order.
3. Run the two bases on all gold_v2 items with GCD on/off.
4. Train both families with an identical QLoRA recipe; run both fine-tunes on
   all gold_v2 items with GCD on/off.
5. For each base and fine-tune retain its better deterministic GCD mode, then
   run temperatures 0.0/0.1/0.3/0.7 with seeds 0–4.
6. Keep temperature 0 unless another temperature gains at least two absolute
   EX points and the paired item-clustered bootstrap 95% interval excludes
   zero. Resolve eligible temperature ties by valid SQL, p95, then lower
   temperature.
7. Compare the four eligible artifacts. A difference below two EX points or
   a paired interval containing zero is a tie. Resolve the tie pool by valid
   SQL, worst-tier EX, p95, then bundle size.
8. Calibrate N=3 always-vote mode for the selected artifact, then require
   all-200 Python/Swift parity with EX and valid-SQL deltas each at most two
   points and every item disagreement explained.

The bootstrap uses seed 424242 and 10,000 replicates. Five seed scores are
averaged within each item before gold-item clusters are resampled.

## Gate 1: family screen

`eval/analyses/screen-c73e14c5f7b91c79/analysis.json` selected:

| Rank | Family’s best cell | EX | Valid SQL | Worst-tier EX | p95 | Size |
|---:|---|---:|---:|---:|---:|---:|
| 1 | Qwen2.5-Coder-3B, GCD on | 35.00% | 85.00% | 16.67% | 14.803 s | 1,747,851,791 B |
| 2 | XiYanSQL-QwenCoder-3B, GCD off | 31.67% | 88.33% | 0.00% | 2.344 s | 1,747,786,195 B |
| 3 | Qwen2.5-Coder-1.5B, GCD off | 23.33% | 70.00% | 0.00% | 1.367 s | 880,172,100 B |
| 4 | Qwen3-1.7B, GCD off | 20.00% | 73.33% | 0.00% | 1.752 s | 984,015,687 B |

Qwen2.5-Coder-3B and XiYanSQL-QwenCoder-3B therefore advanced. The 3.33-point
screening difference did not select production; it selected which families
received the expensive full-gold and training work.

## Gate 2: deterministic base configurations

`eval/analyses/gcd-384235bf4455a900/analysis.json` selected GCD off for both
bases:

| Base | Selected GCD | EX | Valid SQL | Worst-tier EX | p95 |
|---|:---:|---:|---:|---:|---:|
| Qwen2.5-Coder-3B | off | 22.00% | 76.00% | 11.11% | 2.782 s |
| XiYanSQL-QwenCoder-3B | off | 28.50% | 88.00% | 0.00% | 1.697 s |

The larger gold_v2 set reverses Qwen’s gold_v1 GCD choice: GCD on falls to
15.50% EX and 67.50% valid SQL with a 13.265 s p95. This is why the screen’s
GCD result is not reused as a global or permanent default.

## Gate 3: deterministic fine-tuned configurations

Both finalist runs used seed 424242, 600 iterations, batch size 4, 16 adapted
layers, learning rate 1e-4, prompt masking, and the same byte-reproduced
corpus. The complete evidence is in `docs/training-report.md`.

`eval/analyses/gcd-f929b94733b949c3/analysis.json` selected:

| Fine-tune | Selected GCD | EX | Valid SQL | Worst-tier EX | p95 |
|---|:---:|---:|---:|---:|---:|
| Qwen2.5-Coder-3B derivative | on | 52.50% | 89.50% | 33.33% | 2.973 s |
| XiYanSQL-QwenCoder-3B derivative | on | 65.50% | 93.00% | 38.89% | 3.009 s |

For Qwen, GCD on and off tie at 52.50% EX; valid SQL selects on (89.50%
versus 86.00%). For XiYan, GCD on leads off by 0.5 EX points, 0.5 valid-SQL
points, and 5.56 worst-tier points, so on wins before latency is consulted.

Fine-tuning improved the selected Qwen base by 30.5 absolute EX points and the
selected XiYan base by 37.0 points. These gains qualify both fine-tunes for
the temperature comparison but do not, by themselves, select production.

## Gate 4: standardized temperature

All four artifacts ran temperatures 0.0, 0.1, 0.3, and 0.7 with seeds 0–4
over the complete gold_v2 set. No nonzero temperature passed the two-part
eligibility rule, so every artifact retained temperature 0.

| Artifact | Temperature 0 EX | Best nonzero EX | Nonzero difference / 95% CI | Selected |
|---|---:|---:|---|---:|
| Qwen base | 22.00% | 24.30% at 0.3 | +2.30 [−0.60, +5.20] points | **0.0** |
| XiYan base | 28.50% | 28.10% at 0.1 | −0.40 [−2.30, +1.50] points | **0.0** |
| Qwen fine-tune | 52.50% | 52.50% at 0.3 | 0.00 [−1.60, +1.40] points | **0.0** |
| XiYan fine-tune | 65.50% | 66.00% at 0.1 | +0.50 [−0.10, +1.30] points | **0.0** |

The analyses are
`temperature-23f4f07cabbd4400`,
`temperature-46d94aff8e48f2d6`,
`temperature-139fa44908f7b7df`, and
`temperature-2d63595b7361e9d3` under `eval/analyses/`. Each records all
20 source-run manifest hashes for its artifact.

## Gate 5: production artifact

`eval/analyses/production-cddac7c992c20eae/analysis.json` selected the
XiYan fine-tune with GCD on and temperature 0:

| Artifact | EX | Valid SQL | Worst-tier EX | p95 |
|---|---:|---:|---:|---:|
| **XiYan fine-tune** | **65.50%** | **93.00%** | **38.89%** | 3.056 s |
| Qwen fine-tune | 52.50% | 89.50% | 33.33% | 3.017 s |
| XiYan base | 28.50% | 88.00% | 0.00% | 1.712 s |
| Qwen base | 22.00% | 76.00% | 11.11% | 2.842 s |

The XiYan fine-tune is not statistically tied with any alternative. Its
paired EX difference from the runner-up Qwen fine-tune is +13.0 points with
a 95% interval of [+6.5, +19.5]. The public winner candidate is pinned at
`hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit`
revision `7f97a54819b9329338a5353266d6d2a1294eb341`.

## Production verification

All post-selection gates passed. N=3 always-vote calibration selected two
temperature-0.7 samples around the deterministic temperature-zero anchor:
66.80% EX and 95.40% valid SQL over 1,000 item-trials. Full-gold parity
measured Python at 65.50% EX / 93.00% valid SQL and Swift at 65.00% /
92.00%; the 0.50- and 1.00-point absolute deltas pass the two-point gate, and
all 14 disagreements are explained.

`model-manifest.json` is therefore fail-closed at `production_status:
verified`, selecting `ft-xiyansql-qwencoder-3b`, GCD on, deterministic
temperature 0.0, and the calibrated N=3 voting policy. See
`eval/analyses/consistency-926c85c7ebc25eae/analysis.json`,
`eval/analyses/parity-cda177e757fbb0b6/analysis.json`, and
`docs/parity-report.md`.

## Legacy PR #1 selection — not reproducible

The merged PR reported a Qwen2.5-Coder-3B-derived fine-tune as its winner.
Those historical outputs remain in `eval/runs/legacy-pr1-merged/`, explicitly
marked `incomplete-provenance`; they are not a current model-selection claim.
