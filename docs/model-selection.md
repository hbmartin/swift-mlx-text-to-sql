# Model selection

The empirical record behind the bundled-model decision (PRD §8.2: "no
pre-selection — the winning model is chosen by the eval harness").

## Candidates

All ≤4B, 4-bit, run locally from `models/` (downloads confined to the repo):

| shorthand | model | provenance |
|---|---|---|
| q25c-3b | Qwen2.5-Coder-3B-Instruct-4bit | mlx-community, ready-made |
| q25c-15b | Qwen2.5-Coder-1.5B-Instruct-4bit | mlx-community, ready-made |
| q3-17b | Qwen3-1.7B-4bit | mlx-community, ready-made (thinking suppressed via chat template) |
| xiyan-3b | XiYanSQL-QwenCoder-3B-2502 | dedicated text-to-SQL fine-tune (PRD Appendix A "recommended base"), converted + 4-bit-quantized locally via `mlx_lm convert` |
| ft-3b | q25c-3b + in-domain QLoRA (M6) | trained on the 1,424-pair synthetic set |

## Stage 1 — 60-item gold (gold_v1), greedy, single-shot

| config | EX | valid SQL | T1 | T2 | T3 | s/item | top failure buckets |
|---|---|---|---|---|---|---|---|
| q25c-3b-gcdon | **0.350** | 0.850 | 0.70 | 0.17 | 0.20 | 5.3 | wrong-filter-or-value 9, execution-error 9, wrong-projection 7 |
| q25c-3b-gcdoff | 0.333 | 0.783 | 0.70 | 0.13 | 0.20 | 2.7 | execution-error 13, wrong-filter-or-value 10 |
| xiyan-3b-gcdoff | 0.317 | 0.867 | 0.65 | 0.20 | 0.00 | 3.9 | wrong-filter-or-value 15, execution-error 8 |
| xiyan-3b-gcdon | 0.267 | 0.800 | 0.60 | 0.13 | 0.00 | 4.8 | wrong-filter-or-value 14, execution-error 12 |
| q25c-15b-gcdoff | 0.233 | 0.717 | 0.60 | 0.07 | 0.00 | 1.1 | execution-error 17 |
| q3-17b-gcdoff | 0.200 | 0.750 | 0.45 | 0.10 | 0.00 | 2.0 | execution-error 15 |
| q25c-15b-gcdon | 0.200 | 0.533 | 0.55 | 0.03 | 0.00 | 3.2 | execution-error 28 (degenerate `TOTAL(` loops) |
| q3-17b-gcdon | 0.183 | 0.733 | 0.45 | 0.07 | 0.00 | 6.6 | execution-error 16 |

### Stage-1 readings

1. **Qwen2.5-Coder-3B leads.** The general-purpose coder beats the
   *dedicated SQL fine-tune* (XiYanSQL) on this schema. Cross-domain SQL
   training doesn't confer the thing that matters here — this portfolio's
   canonical semantics — and XiYan scored 0.00 on tier 3.
2. **GCD interacts with model strength.** It adds EX and validity on the
   leader (+1.7 EX, +6.7 valid), but *subtracts* on XiYan (−5.0 EX) and on
   the 1.5B, where masking drives degenerate `TOTAL(TOTAL(…` recursion
   until the token cap (valid SQL 0.72 → 0.53). The PRD's "hidden cost of
   structure" caveat is real and model-dependent — GCD on/off must stay a
   per-model axis, not a global setting.
3. **The failure mass is canonical semantics.** Across configs, dominant
   buckets are wrong-filter-or-value and execution-error — models not
   knowing Active+Holdover, latest-month vacancy, "hold" ≠ Sold, or
   referencing invented aliases. Tier-1 mechanical SQL is mostly fine.
   This is precisely the in-domain fine-tuning target (PRD §8.2), and it
   drove the training-data mix (70% tier-2 shapes).
4. Qwen3-1.7B underperforms both Qwen2.5-Coder sizes on SQL; eliminated.
5. Judge note on EX: order-insensitive multiset comparison; several
   "wrong-projection" misses are the model selecting extra/fewer columns
   than the question asked — real misses under the product's definition
   (the user sees the wrong table), kept as failures.

## Stage 2 — 200-item gold (gold_v2): leader baseline vs fine-tune

Configs: `s2-q25c-3b-gcd{on,off}` (baseline) vs `s2-ft-3b-gcd{on,off}`
(QLoRA: 600 iterations, batch 4, 16 layers, lr 1e-4, prompt-masked, on the
1,353-pair train split; adapter fused and re-quantized 4-bit).

Results: see the table in `docs/final-report.md` (generated from
`eval/out/s2-*.summary.json` by `tools/leaderboard.py`).

## Parity check (Swift CLI)

`creg-eval-cli` re-scores the selected model on the production MLX-Swift +
MLXStructured stack over gold_v1; the Python↔Swift EX delta and causes are
recorded in the final report.

## Decision

Recorded in `docs/final-report.md` once stage 2 and parity complete: the
bundled model is the highest gold-v2 EX config, with the fine-tune shipping
only if it beats the best off-the-shelf configuration (plan decision 13).
