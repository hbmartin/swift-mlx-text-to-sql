# Verified production-selection leaderboard

This leaderboard contains each artifact’s statistically selected
configuration over all 200 gold_v2 items and five seeds. The complete
four-way decision is
`eval/analyses/production-cddac7c992c20eae/analysis.json`.

| Rank | Artifact | GCD | Temp. | EX | Valid SQL | Worst-tier EX | p95 |
|---:|---|:---:|---:|---:|---:|---:|---:|
| 1 | **XiYanSQL-QwenCoder-3B QLoRA** | on | 0.0 | **65.50%** | **93.00%** | **38.89%** | 3.056 s |
| 2 | Qwen2.5-Coder-3B QLoRA | on | 0.0 | 52.50% | 89.50% | 33.33% | 3.017 s |
| 3 | XiYanSQL-QwenCoder-3B base | off | 0.0 | 28.50% | 88.00% | 0.00% | 1.712 s |
| 4 | Qwen2.5-Coder-3B base | off | 0.0 | 22.00% | 76.00% | 11.11% | 2.842 s |

Every artifact retained temperature 0 because no nonzero setting improved
mean EX by at least two points with a paired interval excluding zero. The
XiYan fine-tune is the sole production tie-pool member; its +13.0-point
advantage over the Qwen fine-tune has a paired 95% interval of
[+6.5, +19.5] points.

The selected artifact subsequently passed N=3 calibration and the blocking
all-200 Swift parity gate. Production single-shot results are 65.50% EX /
93.00% valid SQL in Python and 65.00% / 92.00% in Swift. The calibrated
always-vote policy reached 66.80% EX / 95.40% valid SQL over 1,000
item-trials. `model-manifest.json` now marks the exact public revision and
generation configuration `verified`.

Historical PR #1 tables are preserved under
`eval/runs/legacy-pr1-merged/` and marked `incomplete-provenance`; they are not
current leaderboard entries.
