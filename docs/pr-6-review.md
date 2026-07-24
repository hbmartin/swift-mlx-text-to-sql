# PR #6 Review: reliability-v3 corpus, training, and bundle gates

- **PR**: [#6 — Implement reliability-v3 corpus, training, and bundle gates](../../pull/6)
- **Branch**: `codex/reliability-v3-corpus-gates` → `main`
- **Scope**: 58 files, +72,073 / −1,907
- **Review date**: 2026-07-23

## Overview

Large but well-organized PR. The 72k added lines are ~95% regenerated corpus artifacts —
three 21k-line `split_manifest.json` files plus JSONL corpora. The reviewable surface is
~2,500 lines:

- **Corpus** (`fine-tuning/synth/generate_training.py`): structural covering matrix
  (metric × operation × grouping × time-grain × scope), paired direct/repair binding
  examples, an SQL-structure-signature train/valid split with zero-overlap enforcement,
  and deterministic 5/10/20% repair-ratio variants.
- **Evaluation** (`fine-tuning/eval/run_eval.py`, `fine-tuning/tools/evaluate_checkpoints.py`):
  multi-snapshot EX — every item must match gold on the production DB plus two committed
  counterexample SQLite snapshots; checkpoint ranking now puts valid-SQL rate before EX.
- **Promotion** (`fine-tuning/tools/analyze_promotion_eligibility.py`,
  `fine-tuning/eval/campaign.py`, `fine-tuning/tools/promote_experiment.py`,
  `fine-tuning/tools/sync_wandb.py`): a new eligibility receipt (binding 15×5,
  paired-bootstrap EX non-inferiority, valid-SQL non-inferiority, tier-3 improvement,
  wrong-table/join ceiling) that is bound to the exact selected checkpoint SHA and
  required at plan, promote, and winner-selection stages.
- **Training integrity** (`fine-tuning/tools/run_experiment.py`): post-run log
  verification rejecting non-finite loss, non-monotone or impossible token counters, and
  truncated logs; gradient checkpointing is now mandatory.
- **App** (`CREG.xcodeproj/project.pbxproj`, `CREGKit/Sources/CREGFeatures/ChatFeature.swift`,
  `CREGKit/Sources/CREGEngine/SQLGenClient.swift`): Debug and Release both bundle the
  verified manifest-selected model; the Hub-download fallback and `HubArtifactDownloader`
  are deleted entirely.

The design is consistently fail-closed, every gate has a negative test, and the
Swift/Python prompt-hash parity contract was updated on both sides in lockstep
(`EngineTests.swift` and `test_prompt_contract.py` both moved to `f9edfd02…`). This is
high-quality work overall; the findings below are mostly hardening and drift-risk items,
not blockers.

## Correctness issues

- **`database_set_sha256` is order-dependent** (`fine-tuning/eval/run_eval.py`): the
  identity is the hash of snapshot digests joined *in `--database` argument order*.
  `analyze_promotion_eligibility` then requires exact equality between candidate and
  baseline. A baseline run invoked with the same three databases in a different order
  will be rejected as a mismatched set. Sort the digests before hashing (or document the
  required order in the `--database` help text).
- **Bare `StopIteration` in winner selection** (`fine-tuning/eval/campaign.py`,
  `select_campaign_winner`):
  `canonical = next(item for item in recipe_manifests if item["experiment"]["seed"] == 424242)`
  has no default. The 4-recipe/12-manifest count check doesn't guarantee each group
  contains the canonical seed, so a malformed input set dies with an opaque
  `StopIteration` instead of a `CampaignSelectionError`. Use `next((…), None)` and raise
  explicitly.
- **Multi-snapshot taxonomy can mis-bucket** (`fine-tuning/eval/run_eval.py`): the
  per-item `error` is the *first* error from *any* snapshot, but `taxonomy()` receives
  the *primary* snapshot's `predicted`/`gold` executions. A query that succeeds on the
  primary DB but errors on a counterexample snapshot passes an error string alongside a
  non-None predicted execution — a combination the taxonomy was not written for. Rare
  (data-dependent SQLite errors), but worth passing the erroring snapshot's executions
  or the primary error only.
- **`sql_structure_signature` over-abstracts in the comma-AS branch**
  (`fine-tuning/synth/generate_training.py`): for `SELECT a, b AS c`, the
  `lowered in {"with", ","}` branch registers `b` — the projected *expression*, not an
  alias — so `SELECT a, b AS c` and `SELECT a, d AS c` hash identically. This errs
  conservative for the leakage gate (over-merging only widens the train exclusion), but
  it silently collapses distinct structures in the `structural_matrix` accounting.
  Restricting that branch to CTE position (after `WITH` or inside a CTE list) would fix
  it.

## Consistency / drift risks

- **Eligibility-receipt validation is triplicated** with different strictness:
  `campaign.validate_eligibility` checks schema/analysis/pass/recipe/model/checkpoint;
  `promote_experiment.require_promotion_eligibility` skips `schema_version`;
  `sync_wandb.attach_selection_evidence` checks schema but not `recipe`/`model_key`.
  These will drift. Extract one validator (e.g., into `eval/campaign.py`) and reuse it
  in all three tools.
- **`evaluate_checkpoints.py` hardcodes `"evaluator_row_cap": 10_000`** while
  `run_eval.py` records the imported `ROW_CAP` (currently 10,000). If `ROW_CAP` ever
  changes, the checkpoint protocol receipt silently disagrees. Import `ROW_CAP` here
  too.
- **Winner selection doesn't verify a shared baseline across receipts**: each receipt
  internally enforces a matched candidate/baseline snapshot set, but the four receipts
  fed to `select-winner` could reference four different baseline *runs*. The gates
  config pins the baseline protocol, so metric drift is bounded, but asserting one
  common `database_set_sha256`/baseline across all used receipts would close the gap.
- **Backward compatibility of W&B sync** (`fine-tuning/eval/wandb_evidence.py`):
  `corpus_sha256` now reads `corpus.variant.sha256`. Re-syncing a schema-v2-era run
  manifest (which has `corpus.manifest.sha256`) will upload `corpus_sha256: None`
  without complaint. If old runs are ever re-synced, fail loudly instead.

## Style / minor

- Mis-indented dict entries introduced in `test_binding_regressions.py`
  (`test_production_finalization_locks_gold_v2_to_gold_v1_winner`) and
  `test_selection.py` — 12-space indent on the first two keys, 8 on the rest; looks
  like a search-replace artifact.
- `promotion_plan`'s `eligibility_run_ids` lists *all* supplied receipts, including
  ones matching no manifest — cosmetic, but slightly misleading in the plan output.
- `default_run_id` now always appends `-db-<hash12>`, even for default single-DB runs —
  fine if intended, but it changes the run-ID format for all future runs.
- Eligibility receipts embed absolute filesystem paths (`inputs.*.path`) — fine for
  local evidence, but they'll leak home-directory paths if receipts are committed or
  uploaded.

## Performance, security, tests

- Multi-snapshot EX triples per-item SQL executions; with a 10k row cap and 60-item
  gold set this is negligible. The 10k-sample bootstrap over 60 paired differences is
  also cheap and correctly seeded for determinism.
- No security concerns: subprocess invocations use fixed argument lists, snapshot
  generation refuses symlinked bases and writes atomically via `os.replace`, and the
  pbxproj script keeps `set -euo pipefail`. Removing the runtime Hub download path
  *reduces* supply-chain surface — the app can now only load the hash-verified bundled
  snapshot.
- Test coverage is a highlight: every new gate has both a passing and a refusing test
  (mixed-checkpoint binding evidence, failed binding receipt, missing eligibility,
  non-finite loss, impossible token counters, byte-identical snapshot regeneration,
  corpus variant invariants), and `test_ci_contracts.py` pins the build-phase and Swift
  source contracts — brittle by design, consistent with the project's contract-test
  idiom.

## Process note

At review time the local checkout was on the PR branch but had uncommitted
modifications to several PR files (`ChatFeature.swift`, `test_ci_contracts.py`,
`fetch_model.py`, `project.pbxproj`, both READMEs). This review is based on the PR diff
via `gh pr diff`, not the working tree — if those local edits are follow-ups to review
feedback, they are not reflected above.

## Verdict

Approve with minor changes. The two items to fix before merge are the order-dependent
`database_set_sha256` (it will bite the first manually-invoked baseline run) and the
bare `StopIteration` in `select_campaign_winner`.
