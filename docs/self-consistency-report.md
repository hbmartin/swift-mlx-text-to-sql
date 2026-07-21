# Self-consistency calibration report

Status: **temperature 0.7 selected for samples**.

The authoritative analysis is
`eval/analyses/consistency-926c85c7ebc25eae/analysis.json` (SHA-256
`ea86dbe3beb81395a0f9b5aa7fa5ec58b2ac594099c558c51dfcd90c07ba1e5f`).
It reuses immutable runs only after verifying their complete frozen-input and
generation contract.

## Method

Every trial contains exactly three Candidate Queries:

1. one executed deterministic anchor at temperature 0.0; and
2. two independently seeded consistency samples at the tested temperature.

The policy always votes. A Result Group needs a strict majority of all three
candidates. Failed and truncated candidates count in the denominator. No
Consensus selects a complete anchor with a visible notice; an unavailable or
truncated anchor can retain a successful primary only as a visible degraded
fallback.

All 200 gold_v2 items were evaluated for trial seeds 0–4, producing 1,000
item-trials and 3,000 Candidate Queries per sample temperature.

## Results

| Sample temperature | EX | Valid SQL | Consensus | No Consensus | Anchor failures | Mean latency | p95 latency |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.1 | 65.60% | 93.60% | 931 | 2 | 70 | 6.614 s | 9.178 s |
| 0.3 | 65.80% | 93.80% | 920 | 13 | 70 | 6.626 s | 9.441 s |
| **0.7** | **66.80%** | **95.40%** | 893 | 40 | 70 | 6.643 s | 9.158 s |

Temperature 0.7 wins on both EX and valid SQL. It raises EX 1.3 points and
valid SQL 2.4 points relative to the deterministic single-shot production
cell, at roughly 2.17× its p95 latency. This is a calibration result over
five repeated trials, so it is reported separately from the 200-item
single-shot score.

The anchor-failure count is 14 deterministic failures repeated across five
trial seeds. Higher sample temperature improves aggregate correctness but
also reduces agreement: No Consensus rises from 2 at temperature 0.1 to 40
at 0.7. The visible anchor fallback is therefore part of the selected
contract, not an exceptional undocumented branch.

## Production decision

The manifest keeps normal generation deterministic at temperature 0.0 and
sets only the two consistency samples to temperature 0.7. It records:

- `candidate_count: 3`;
- `always_vote: true`;
- `sample_temperature: 0.7`; and
- evidence linking this analysis, production selection, both publications,
  and full-gold parity.

Every nonzero-temperature runtime candidate receives a fresh
cryptographically random UInt64 seed, which is passed to MLX and persisted
with the candidate telemetry for replay and audit.
