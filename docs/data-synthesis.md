# Data synthesis notes

How every dataset in this project was produced, gated, and judged. This round
was run autonomously: per the user's instruction, test data was fabricated by
Claude and Claude served as the judge (in place of the PRD's Claude-Opus-CLI
judge + human sign-off).

## 1. The bundled portfolio database

`fine-tuning/tools/generate_db.py`, seed 20260719, AS_OF 2026-07-01,
36-month financials window (2023-07 → 2026-06). ~2,500 rows over seven
tables. Internal consistency is the point: the correction heuristics and the
gold results are only trustworthy if the data obeys its own accounting.
Invariants (all enforced by `tests/test_invariants.py`):

- `EGI = GPR − vacancy_loss` and `NOI = EGI − opex` exactly (to the cent)
- `occupancy_rate` = occupied leased sqft / rentable sqft at each month-end,
  where occupied = leases covering that date (Holdover counts, Pending never)
- `annual_base_rent = base_rent_psf × leased_sqft`
- per-suite lease chains never overlap in time
- statuses agree with dates relative to AS_OF; Terminated stores the actual
  early-exit date; Sold properties stop accruing financials at disposition
- loans amortize correctly (`current ≤ original`, `ltv = current/value`,
  DSCR = TTM NOI / annual debt service); the latest valuation tracks
  `current_market_value` within 5%

One deliberate quirk found during gold review: converting three recently
expired leases to Holdover (so the status exists in data) *filled* the
vacant suites of exactly the highest-vacancy properties — the top-vacancy
list changed versus pre-Holdover data. Verified consistent, kept.

## 2. Gold set

### Stage 1 — 60 hand-written items (`eval/gold/gold_v1.jsonl`)

Tiers: 20 × T1 (single-table), 30 × T2 (joins/aggregates/dates),
10 × T3 (windows/CTEs/nesting), including 2 fuzzy-entity items (misspelled
"Kingsly Tower", partial "Yates Medical"), 1 tagged-ambiguous item with a
best-guess gold ("exposure in New York"), and 2 multi-turn items carrying
`history` + a `standalone` rewrite (the harness evaluates the standalone
form; the rewrite itself is the FM's job).

Canonical semantics encoded (see ADR 0001): vacancy = 1 − occupancy_rate at
each property's latest Month row; "rent roll"/"occupy" = status IN
(Active, Holdover); "currently hold" = status ≠ Sold; current value =
`properties.current_market_value`; "next 12 months" = [2026-07-01,
2027-07-01). Questions were phrased to pin the expected projection
("show tenant, property, and expiration date") because EX compares full
result sets.

### Stage 2 — +140 generated items → 200 (`eval/gold/gold_v2.jsonl`)

`tools/expand_gold.py`, seed 20260719: 24 template families instantiated
over real entities (property/tenant/fund/market names sampled from the DB),
2–3 paraphrase templates per family. Kept 140/140 after gating.

### Gate + judge protocol (both stages)

`tools/validate_gold.py` machine-checks every item: executes against
`creg.sqlite`; flags empty/NULL-scalar results; verifies the gold SQL is
**accepted by the decoding grammar** (a gold query the grammar can't
represent would make that item unwinnable under GCD — this check runs both
directions: it caught the grammar's missing SELECT-alias references, fixed
in `generate_grammar.py`). Reports: `docs/gold-review-v1.md`,
`docs/gold-review-v2.md` — 0 flagged in both.

Judge pass (Claude, this round): reviewed all 60 stage-1 result samples
against the questions (rubric: executes / question↔SQL alignment / sensible
result / SQLite dialect / canonical form). One anomaly investigated (the
Holdover-vacancy interaction above); no items rejected. Stage-2 items
inherit family-level judgment: each family's SQL shape was reviewed once,
and every instantiation is execution-validated.

## 3. Synthetic training data (`fine-tuning/synth/`)

`synth/generate_training.py`, **seed 424242** (deliberately different from
the gold seed so entity samples differ). ~45 template families ×
paraphrase rotation × entity/timeframe combinatorics → 2,006 raw
candidates → **1,424 kept** (357 T1 / 1,003 T2 / 64 T3), split 1,353 train /
71 valid. The tier-2 weighting is intentional: the stage-1 eval shows base
models fail overwhelmingly on tier-2 canonical semantics.

Quality gate per candidate (stats logged to `synth/out/gate_stats.json`):

1. executes without error against the real DB
2. non-degenerate result
3. accepted by the decoding grammar (training never teaches SQL the runtime
   grammar would mask away)
4. **not present (normalized-string match) in the 200-item gold set** —
   plus the structurally stronger control that gold stage 1 is hand-written
   and both generators use different seeds
5. batch-level dedup

Format: chat JSONL whose system prompt is byte-identical to the app's
runtime prompt (schema serialization + canonical rules + today's date), so
the model trains on exactly the distribution it will see. Assistant turn is
the bare SQL.

Deliberate exclusions, per the runtime architecture: no multi-turn examples
(the FM rewrites follow-ups into standalone questions before the SQL model
ever sees them) and no clarification behavior (that's the FM ambiguity
gate). EXISTS-based SQL is avoided in favor of `NOT IN (SELECT …)` because
the frozen grammar does not include EXISTS.

Leakage accounting: 2 of 2,006 raw candidates collided with gold questions
and were dropped by the gate; the exact-match dedup plus seed separation is
the leakage control for this round. Family *shapes* intentionally overlap
with gold — teaching the schema's canonical query shapes is the entire
purpose of in-domain fine-tuning (PRD §8.2).
