# CREG v1 — Final Report

**v1 is complete per plan decision 13:** the app runs the full corrected
pipeline on device, the eval harness selected the model empirically, the
fine-tune loop was closed end-to-end once, and the fine-tuned model won by a
wide margin and is bundled. This report records every consequential choice
of the autonomous run (2026-07-19) and its outcome. Companion notes:
`docs/data-synthesis.md`, `docs/eval.md`, `docs/grounding-corrections.md`,
`docs/model-selection.md`, ADRs in `docs/adr/`.

Run ground rules set by the user: fabricate test data as needed; Claude as
judge for this round; all downloads confined to the repo (`models/`,
including the HF cache); detailed notes in `docs/`.

## Headline result

| | EX (200-item gold) | valid SQL | tier 2 | s/item |
|---|---|---|---|---|
| Best off-the-shelf (Qwen2.5-Coder-3B, no GCD) | 0.225 | 0.760 | 0.11 | 3.1 |
| **CREG fine-tune (same base + in-domain QLoRA, GCD on)** | **0.665** | **0.930** | **0.70** | **2.9** |

The PRD's central bet — that a single fixed schema plus in-domain
fine-tuning beats generic capability — is confirmed: **+44 EX points (~3×)**
from 1,353 synthetic training pairs and ~90 minutes of Mac training time.

The honest decomposition, because it defines the next iteration: splitting
gold_v2 into its 60 hand-written items and 140 template-generated items,

| slice | base | fine-tune |
|---|---|---|
| generated 140 (in-family phrasings) | 0.071 | **0.786** |
| hand-written 60 (novel phrasings) | 0.350 | 0.383 |

The fine-tune fully learned the schema's canonical semantics *as expressed
by the template families* but transfers weakly to novel phrasings —
template-side paraphrase rotation is not a substitute for the PRD's
dev-time LLM paraphrase step (§13 method 4), which is the top data
priority for iteration two. The ship decision is unaffected: the
fine-tune ≥ base on every slice.

## The choices, in order, and why

1. **Schema semantics were frozen before any modeling** (ADR 0001):
   month-only financials grain, snapshot vacancy, valuations-as-history,
   no units table. Every later stage (grammar, gold set, training data,
   prompts) encodes these rules identically — which is exactly why the
   fine-tune could learn them.
2. **Grammar via mlx-swift-structured (XGrammar), not MLXGuidedGeneration**:
   the PRD's first choice does not exist on GitHub; the spike took an hour
   and settled it. The grammar is generated from the live DB, SELECT-only,
   with hallucinated tables unrepresentable; two deliberate openings (free
   string literals, bare alias identifiers) route residual failures to the
   correction layers instead. Gold queries are round-tripped through the
   grammar in validation, which caught a missing alias-reference production.
3. **Candidates were four ≤4B 4-bit models** (both Qwen2.5-Coder sizes,
   Qwen3-1.7B, and XiYanSQL-3B converted locally). Stage-1 (60 gold):
   the general coder Qwen2.5-Coder-3B (0.350) beat the *dedicated SQL
   fine-tune* XiYanSQL (0.317) — cross-domain SQL skill does not transfer
   to this schema's canonical semantics, which is the PRD's thesis restated
   from the other side.
4. **GCD is a per-model decision, empirically**: it helped the leader on
   easy gold (+1.7 EX), *hurt* it on hard gold (−7 EX), drove the 1.5B into
   degenerate `TOTAL(TOTAL(…` loops, and cost the fine-tuned model exactly
   nothing (0.665 both ways). Decision: **ship with GCD on** — for the
   fine-tuned model the structural guarantees (SELECT-only, no invented
   tables) are free.
5. **The gold set was deliberately made harder as it grew**: the 140
   generated stage-2 items concentrate per-entity canonical-semantics
   questions (the app's real distribution), which is why base-model EX
   *fell* from 0.350 to 0.155–0.225 while the fine-tune hit 0.665. The gap
   is the point: it measures the semantics, not generic SQL.
6. **Training data = 1,424 template-generated pairs** (seed-separated from
   gold, normalized-question dedup, every pair executed + grammar-checked;
   2 gold collisions dropped). System prompt byte-identical to the runtime
   prompt. Trained: QLoRA 600 iters, batch 4, 16 layers, lr 1e-4,
   prompt-masked; fused with quantization preserved.
7. **Correction layers were built before the model was chosen** so they are
   model-independent: fuzzy-literal suggestions (layer A), self-repair
   (layer 2), self-consistency voting gated on deterministic uncertainty
   proxies (C+D), narration-as-confirmation (B). The harness's entropy
   logging now supplies the empirical layer-D threshold for the fine-tuned
   model: correct answers average 0.017, wrong 0.066 — a clean 4×
   separation (base model: 0.31/0.41, nearly useless). Proxy triggers were
   the right v1 call; entropy gating at ~0.03 is the v1.1 upgrade.
8. **Claude as judge** (this round, per user instruction): gold stage 1 was
   authored and result-reviewed item-by-item; stage 2 and training data
   were judged at family level with per-item machine gates (execute /
   non-degenerate / grammar / dedup). The audit trail is
   `docs/gold-review-v*.md` + `synth/out/gate_stats.json`.

## Fine-tune failure taxonomy → next-iteration priorities

67/200 still miss. Reading the misses: (a) **template echo** — memorized
filters surfacing where they don't belong (train loss 0.001 = overfit;
next run: fewer iterations or 10× phrasing diversity); (b) one **canon
inconsistency** the loop exposed: training taught "hold" = `!= 'Sold'`
while gold T1-04 reads "owned" = `= 'Owned'` — add contrast pairs;
(c) **tier-3 volume** (0.278 EX; only 64 of 1,424 training pairs were
tier-3 — raise to ~300); (d) fuzzy/multi-turn items still depend on the
runtime correction layers, as designed.

## Parity check (Swift production stack)

`creg-eval-cli` (the app's exact MLX-Swift + MLXStructured + prompt stack,
built via xcodebuild because SPM CLI builds of mlx-swift lack the Metal
library) re-scored the bundled model on the 60-item gold set:

| runtime | EX (same 60 items) | valid SQL | disagreements |
|---|---|---|---|
| Python harness (mlx_lm + xgrammar) | 0.383 | 0.817 | — |
| Swift production stack | 0.400 | 0.800 | **1 / 60 items** |

One item flipped (Swift's generation chose a different-but-correct query).
The two stacks agree on 59/60 — the Python harness's selections are valid
for what actually ships (ADR 0003's premise holds).

## What ships

- Bundled model: `models/SQLModel` (= fused `creg-sql-3b-ft`,
  Qwen2.5-Coder-3B-Instruct + CREG QLoRA, 4-bit, ~1.7 GB), referenced by
  the Xcode project as an app resource; `SQLGenClient` prefers it over any
  network path — the app is fully offline.
- GCD on (XGrammar EBNF), serializer-guaranteed non-overlapping inference,
  correction layers A–D, developer mode, JSONL session export.

## Deviations from the PRD, all recorded when made

- MLXGuidedGeneration doesn't exist → XGrammar path (PRD anticipated this).
- ~10k rows → ~2.5k with exact accounting invariants (plan decision 6).
- Claude judged instead of Opus-CLI + human sign-off (user's instruction
  for this round).
- Schema-serialization and self-consistency-N harness axes documented but
  not swept (compute budget went to the fine-tune loop, which was the
  decision-relevant experiment).
- Swift-side layer D uses deterministic proxies; entropy threshold comes
  from the harness (see `docs/grounding-corrections.md`).
