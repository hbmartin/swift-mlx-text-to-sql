# Review: PR #4 — Harden post-merge reliability and campaign evidence

Reviewed at commit `fde53be` (branch `codex/pr3-post-merge-follow-up` → `main`).

## Overview

This PR closes several fail-open gaps left after the reliability-v2 merge: it
replaces text-scraped database-failure classification with a typed error, makes
prompt-template substitution single-pass in both Swift and Python, restructures
the release pipeline so the gold-v1 campaign winner is immutable and gold-v2 is
a non-selecting gate, adds supply-chain-hardened CI (SHA-pinned actions, no
persisted credentials, Semgrep guard, corpus-determinism check), and regenerates
the content-addressed corpus with a corrected lease-count vs. tenant-count
split. 46 files, +3235/−1968 — though roughly two-thirds of that is
deterministic corpus regeneration and Black-style reformatting.

The design is sound and the direction is right. However, **the PR's own new CI
is red on this PR**, and the new Semgrep guard demonstrably misses the exact
code pattern it was written to prevent.

## Confirmed issues

**1. The new CI "Security regression guards" job fails —
`git diff --check HEAD^ HEAD` on a depth-1 checkout.**
(`.github/workflows/ci.yml`, "Check patch whitespace" step)

`actions/checkout` defaults to `fetch-depth: 1`, so `HEAD^` doesn't exist. The
job log confirms it: `fatal: ambiguous argument 'HEAD^': unknown revision or
path not in the working tree` (exit 128). Fix by adding `fetch-depth: 2` to
that job's checkout step. This must be fixed before merge — as-is, every PR
will fail this required-looking check.

**2. The Semgrep guard misses the multiline form of the pattern it bans.**
(`.semgrep.yml`, rule `creg-typed-diagnostic-classification`)

The regex
`\.(?:contains|hasPrefix|hasSuffix)\s*\([^\n]*portfolio_database_unavailable`
uses `[^\n]*` after the paren, so it only matches when the string literal is on
the same line as the call. Verified empirically: the single-line form in
`DatabaseClient.swift` is caught, but the code actually removed from
`QueryPipeline+Diagnostics.swift` was line-wrapped
(`.contains(\n  "[portfolio…"`) and is **not** matched. Since long lines get
wrapped by formatters, the guard has a built-in false negative for its primary
target. Replace `[^\n]*` with something newline-tolerant, e.g. `[^)]*` or
`[\s\S]{0,120}?`.

**3. `check_ci_contracts.py` only globs `*.yml`.**
(`fine-tuning/tools/check_ci_contracts.py`)

A future workflow named `*.yaml` silently escapes both the SHA-pin and
persist-credentials checks. Add `*.yaml` to the glob. Also minor: the
persist-credentials check only inspects the 4 lines after
`uses: actions/checkout@…`, so a `with:` block with a few keys before
`persist-credentials` would be misjudged — acceptable today, but brittle.

## Design observations

- **Release-gate loosening: publications went from exactly 2 to 1+.**
  (`finalize_production.py`) The old gate required "both public fine-tune
  snapshots"; the new one accepts a single record. The PR body says this is
  intentional (only the winner is published now), and the
  `derived`/`publication_identities` cross-check still binds records to
  manifest entries — but this is a policy weakening worth a deliberate
  sign-off, not just a mechanical review.
- **Hardcoded winner identity in `aggregate_recipe`.**
  (`fine-tuning/eval/campaign.py`) `"gcd": "on", "temperature": 0.0` are
  asserted constants, not read from the manifests. They do mirror
  `evaluate_checkpoints.py`, which is "intentionally hard-wired to gold_v1,
  GCD-on, temperature-zero" and records those values in `selected["summary"]` —
  so today it's consistent. But copying the constant instead of reading (or
  validating against) `selected["summary"]["gcd"]/["temperature"]` means a
  future change to the checkpoint evaluator would silently desynchronize the
  "locked identity" that `final_evaluation` then enforces. Prefer deriving
  from the summary.
- **The 0.668 EX release floor now exists in two places** —
  `analyze_matrix.final_evaluation` (`release_floor`) and
  `finalize_production.MINIMUM_PRODUCTION_EX`. They agree, and finalize
  re-validates, but a shared constant would prevent drift.
- **`weave_helpers_impl.py` inconsistency:** `_call_row` prefers top-level
  `status_counts` with a `weave` fallback, but `eval_health` dropped the
  fallback entirely. If the fallback matters, `eval_health` should keep it; if
  it doesn't, `_call_row` shouldn't have it. Pick one.

## What's done well

- **Typed error classification** (`PortfolioDatabaseUnavailableError`): the
  factory now also installs a `validate` closure returning a terminal
  `.databaseUnavailable` issue, so both the validation and execution paths
  classify without text parsing. The negative test
  (`databaseFailureClassificationDoesNotScrapeDiagnosticText`) that feeds the
  old marker string through an *untyped* error and asserts generic
  classification is exactly the right regression test.
- **Single-pass template rendering** in both Swift (`renderTemplate`) and
  Python (`re.sub` with a lookup lambda) — the same fix on both sides of the
  parity contract, each with a matching only-once test using
  placeholder-shaped user data. Unknown tokens are preserved identically in
  both.
- **The lease-count / tenant-count intent split** (`prop_active_leases` vs new
  `prop_active_tenants` with `COUNT(DISTINCT l.tenant_id)`) is a genuine
  data-quality fix, and the new corpus test enforces the invariant on the
  generated records.
- **`final_evaluation` rewrite**: replacing production *selection* (4-artifact
  ranking with tie-breaking) with a non-selecting gate that rejects any run not
  matching the locked winner's artifact key/GCD/temperature is a meaningful
  fail-closed improvement, well covered by
  `test_final_gold_v2_evaluation_cannot_replace_the_campaign_winner`.
- **Provenance hardening**: `clean_git_provenance` checked *before* reserving
  the immutable run directory; campaign selection output now embeds schema
  version, selection order, and SHA-256 of all 12 input manifests.
- The narrower SQL-redaction regex is a real improvement — the old one
  redacted any sentence starting with "Select a…"; the new one keeps
  plain-language guidance intact while still catching `SELECT 1` /
  `SELECT char(…)` shapes, with tests for both directions. (Residual edge
  case: a two-word instruction like "Select one" at end-of-string still
  redacts — acceptable.)
- Deleting the accidentally committed `triage_decisions.db` and
  `reviews_triage/*.json` and ignoring them going forward.

## Minor / nits

- `fine-tuning/eval/prompt_contract.py`: `import re` lands between `hashlib`
  and `json` — unsorted; harmless since Ruff's isort rules evidently aren't
  enabled.
- `validate_publication_arguments` dedups on raw `Path` equality, so `a.json`
  vs `./a.json` pass distinctness; resolving before comparing would be
  stricter (downstream identity checks mostly neutralize this).
- `test_wandb_skill_helpers.py` reaches into `.agents/skills/…` via
  `importlib` — a cross-tree coupling that breaks if the vendored skill moves;
  fine as long as that's understood.
- The sweep-config change to module mode (`-m tools.run_experiment`) is
  correct and now enforced by
  `test_sweeps_launch_the_experiment_runner_as_a_python_module`.

## Test coverage & validation

Good: every behavioral change has a targeted test (typed classification,
single-substitution ×2, dirty-worktree rejection, winner immutability ×2,
publication arity, missing base-model key, zero-success efficiency, sweep
module mode, corpus intent split). Swift (87) and Python (140) suites pass in
CI, and the corpus-determinism CI check independently reproduces the committed
corpus byte-for-byte, which retroactively validates the manifest hash updates.

## Verdict

Approve with changes: fix the `fetch-depth` CI failure (blocking — the check
is red on this PR right now), and strongly recommend fixing the Semgrep
regex's multiline blind spot and the `*.yaml` glob gap in the same pass, since
all three are the enforcement mechanisms this PR exists to add. Everything
else is discretionary.
