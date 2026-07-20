# Eval stages & results

Methodology and results for every eval stage. Configs are cells of the PRD
§12 matrix; each run's per-item results and summary live in `eval/out/`
(`<label>.jsonl` + `<label>.summary.json`).

## Methodology

- **Metric:** Execution Accuracy (EX) — order-insensitive multiset equality
  of result sets, reals rounded to 4dp (`fine-tuning/eval/ex.py`). Secondary:
  valid-SQL rate (executes without error), mean seconds/item, EX by tier.
  Queries returning more than 10,000 rows are explicitly unscorable and
  excluded from the EX denominator rather than compared as truncated prefixes.
  The clarification-gated item is likewise excluded from primary SQL EX;
  its annotated best-guess query is retained and reported separately as
  `fallback_sql_ex`.
- **Prompt:** byte-identical to the app's runtime prompt (compact schema
  serialization with enumerated low-cardinality values + canonical-semantics
  rules + fixed today of 2026-07-01). Greedy decoding with a 1.1 repetition
  penalty over the previous 64 tokens, max 512 tokens. Generations that reach
  the cap are classified as `generation-truncated` and are not executed.
- **GCD:** `on` = xgrammar token-bitmask logits processor over the same
  `sql_grammar.ebnf` the app uses; `off` = unconstrained + SQL extraction
  (fence stripping, first statement). Both paths strip leaked chat-template
  special tokens before execution (a 1.5B tokenizer leaked `<|im_end|>`
  into decoded text, zeroing its first run — fixed harness-side). Boolean
  predicate chains are bounded in the grammar to prevent unproductive
  repeated-clause loops.
- **Entropy logging:** per-token pre-mask softmax entropy recorded per item
  (mean/max), correct-vs-wrong aggregates in each summary — the empirical
  input for the layer-D gating threshold.
- **Runtime:** Mac (M2 Pro, 32 GB) via mlx_lm. The Swift parity CLI
  (`creg-eval-cli`, app's exact MLX-Swift + MLXStructured stack) re-scores
  finalists — deltas reported below.

Candidates (PRD Appendix A, MLX 4-bit, all local in `models/`):
`Qwen2.5-Coder-3B-Instruct-4bit`, `Qwen2.5-Coder-1.5B-Instruct-4bit`,
`Qwen3-1.7B-4bit`, and `XiYanSQL-QwenCoder-3B-2502` (dedicated text-to-SQL
fine-tune, converted + 4-bit-quantized via `mlx_lm convert`).

## Stage 1 — base sweep, 60-item gold (gold_v1)

Results table is generated from `eval/out/*.summary.json`; see
`docs/model-selection.md` for the full leaderboard and the selection
decision.

Headline findings:

- Base models hold up on tier 1 (single-table) but collapse on tier 2/3:
  the misses are dominated by **canonical-semantics failures** — not
  knowing that rent roll = Active+Holdover, vacancy = latest-month
  `1 − occupancy_rate`, "currently hold" excludes Sold. Exactly the gap
  in-domain fine-tuning exists to close (PRD §8.2).
- GCD on vs off: +valid-SQL and small +EX on capable models; on the 1.5B
  model, GCD exposed degenerate loops (`TOTAL(TOTAL(…` until token cap) —
  the PRD's "hidden cost of structure" caveat observed in the wild.
- Valid-SQL under GCD is < 100% by design: the grammar's two deliberate
  openings (free string literals, bare identifiers for alias references)
  convert would-be hallucinations into execution errors, which the app's
  self-repair layer then handles (the harness scores single-shot, no
  repair).

## Stage 2 — finalists on the 200-item gold (gold_v2)

Finalists (top stage-1 configs) re-run on the full 200-item set; the
fine-tuned adapter (M6) is evaluated on the same set for the
ship/don't-ship decision. Results in `docs/model-selection.md`.

## Parity check — Swift CLI

`creg-eval-cli --model <dir> --db db/creg.sqlite --gold eval/gold/<set>`
re-scores finalists on the production stack. Python-vs-Swift EX deltas and
their causes are recorded in `docs/model-selection.md`.

## Ablations deferred (documented, not run this round)

Schema-serialization variants (raw DDL vs compact) and self-consistency-N
sweeps were deprioritized to fit the autonomous run's compute budget; the
harness axes exist (`--gcd`, prompt constant swap) and the failure taxonomy
prioritizes canonical-semantics data over prompt-format experiments.
