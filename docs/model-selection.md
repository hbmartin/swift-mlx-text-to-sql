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
| q25c-3b-gcdon | **0.356** | 0.850 | 0.70 | 0.17 | 0.20 | 5.3 | wrong-filter-or-value 9, execution-error 9, wrong-projection 7 |
| q25c-3b-gcdoff | 0.339 | 0.783 | 0.70 | 0.14 | 0.20 | 2.7 | execution-error 13, wrong-filter-or-value 10 |
| xiyan-3b-gcdoff | 0.322 | 0.867 | 0.65 | 0.21 | 0.00 | 3.9 | wrong-filter-or-value 12, wrong-projection 8 |
| xiyan-3b-gcdon | 0.271 | 0.800 | 0.60 | 0.14 | 0.00 | 4.8 | wrong-filter-or-value 12, execution-error 12 |
| q25c-15b-gcdoff | 0.237 | 0.717 | 0.60 | 0.07 | 0.00 | 1.1 | execution-error 16 |
| q3-17b-gcdoff | 0.203 | 0.750 | 0.45 | 0.10 | 0.00 | 2.0 | execution-error 15 |
| q25c-15b-gcdon | 0.203 | 0.533 | 0.55 | 0.03 | 0.00 | 3.2 | execution-error 27 (degenerate `TOTAL(` loops) |
| q3-17b-gcdon | 0.186 | 0.733 | 0.45 | 0.07 | 0.00 | 6.6 | execution-error 16 |

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
1,353-pair train split; adapter fused, quantization preserved). Training
converged to train loss 0.001 / val loss 0.008.

| config | EX | valid SQL | T1 | T2 | T3 | s/item | entropy corr/wrong |
|---|---|---|---|---|---|---|---|
| **ft-3b gcd-on** | **0.663** | 0.930 | 0.714 | 0.697 | 0.278 | 2.9 | 0.017 / 0.066 |
| ft-3b gcd-off | 0.663 | 0.925 | 0.714 | 0.697 | 0.278 | 1.8 | — |
| base gcd-off | 0.226 | 0.760 | 0.388 | 0.182 | 0.111 | 2.9 | — |
| base gcd-on | 0.156 | 0.675 | 0.286 | 0.114 | 0.111 | 6.3 | 0.311 / 0.408 |

### Stage-2 readings

1. **The fine-tune wins decisively: 0.663 vs 0.226 (+44 EX points, ~3×).**
   Tier-2 (canonical semantics) went 0.18 → 0.70. The PRD's "single biggest
   accuracy lever" claim is confirmed on this schema.
2. **gold_v2 is harder for base models than gold_v1** (0.156 vs 0.356
   gcd-on): the 140 generated items concentrate per-entity
   canonical-semantics questions — the app's actual distribution.
3. **GCD is free for the fine-tuned model** (identical EX on/off). The
   model internalized the grammar, so constrained decoding costs nothing
   and keeps its structural guarantees (SELECT-only, no hallucinated
   tables). Ship with GCD on. For *base* models on the harder set, GCD
   *reduced* EX (0.156 vs 0.226) — constraint pressure hurts weak models.
4. **Entropy now works as an uncertainty signal** for the FT model
   (0.017 correct vs 0.066 wrong, 4× separation; base: 0.31/0.41). A
   layer-D threshold near mean entropy ≈ 0.03 is the empirically motivated
   starting point.
5. **Residual failure taxonomy (67 misses)** = template echo from overfit
   (spurious memorized filters: a stray `AND market = …`, dropped
   `rate_type` filters, joins injected where none needed) plus one genuine
   canon inconsistency (training taught "hold" = `!= 'Sold'`; gold T1-04
   reads "owned" as `= 'Owned'`). Next-iteration data priorities: lower
   iterations/LR or more phrasing diversity to cut memorization; add
   owned-vs-held phrasing contrast pairs; more tier-3 volume (0.278).

## Parity check (Swift CLI)

`creg-eval-cli` re-scores the selected model on the production MLX-Swift +
MLXStructured stack over gold_v1; the Python↔Swift EX delta and causes are
recorded in the final report.

## Decision

**Bundled: the CREG fine-tune (Qwen2.5-Coder-3B-Instruct-4bit + in-domain
QLoRA, fused, GCD on), shipped as `models/SQLModel`.** It beats the best
off-the-shelf configuration 0.663 vs 0.226 on gold_v2 and is ≥ base on
every slice (hand-written 0.373 vs 0.356; generated 0.786 vs 0.071), so
plan decision 13's condition is met. The clarification-gated item is reported
separately as fallback SQL and excluded from primary EX. Full narrative
and next-iteration priorities: `docs/final-report.md`.
