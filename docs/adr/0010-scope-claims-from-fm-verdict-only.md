# Scope claims come only from an FM verdict that has seen the schema

## Status

Accepted (2026-08-19).

## Context

When a turn fails, the most useful thing CREG could tell the user is whether
the portfolio covers the question at all. The tempting shortcut is
deterministic inference from SQL errors: a `no such column` naming a concept
absent from every table looks like evidence that the data does not cover it.

Before this decision, every SQL error in all 119 stored eval runs
(`eval/runs/*/*.json`, 460 item rows) was harvested and classified against
`schema_catalog.json`: 44 errors, **every one on a gold-set question that is
by definition answerable**, across exactly 23 distinct gold questions.

| Error shape | Count | Meaning |
|---|---|---|
| Qualified (`ln.status`, `f.name`, `t.market`) | 18 | Wrong alias — the column exists in all 12 distinct cases |
| Bare, column exists somewhere | 15 | Wrong join scope |
| Bare, absent from every table | 8 | `current_rate`, `vacancy`, `year`, `rnk` |

Only the last bucket could ever fire a deterministic scope check, and all
four names are false positives: `current_rate` → `loans.interest_rate`
exists; `year` → date columns exist; `rnk` is a window-function alias, not a
data concept; and `vacancy` is a first-class Portfolio term (CONTEXT.md,
ADR 0001). Measured precision of the rule "unresolved identifier ⇒ the data
doesn't cover it" is **0/41** (the three duplicate-suppression errors carry no
identifier at all).

The worst case is exemplary: `T2-21` — *"What are the five properties with
the highest vacancy right now?"*, semantically the `highest-vacancy-v1`
Starter Query and present in all three gold files — produced
`no such column: vacancy`. A naive scope check would refuse CREG's own
reviewed product query.

A note on the baseline this work replaced: production already differentiated
failure *messages* — `reportingTerminalFailures` classified failures through
a seven-branch ladder — but the differentiation was stringly, lived in a
diagnostics wrapper, and never reached the message body, telemetry, or eval
as data. The defect was representation, not absent differentiation; no part
of that ladder ever made a scope claim either.

## Decision

1. **SQLite binding and execution errors are evidence about the model, never
   about the data.** No deterministic scope inference from SQL errors, ever.
2. **A Scope Verdict comes only from a Foundation Model judgement made with
   the full schema prompt in hand** (`FMClient.scopeVerdict`), enumerated
   over exactly four buckets — `outside_real_estate`,
   `in_domain_but_not_tracked`, `needs_data_not_in_snapshot`,
   `likely_answerable_model_failed` — and biased toward the last, the way
   the Ambiguity Gate prompt biases toward answering.
3. **Every sentence the user reads is written by a human.** The FM picks a
   bucket; the one FM-supplied phrase (`missingSubject`, rendered only for
   `in_domain_but_not_tracked`) passes a deterministic guard
   (`ScopeVerdictGuard`). The guard canonicalizes punctuation and plurals,
   drops schema and portfolio vocabulary, and renders only a human-reviewed
   allowlist of genuinely untracked concepts. Arbitrary FM text is omitted —
   the annotation itself must never make a false scope claim.
4. **The mechanism is measured, not assumed:** the answerability corpus
   (`eval/gold/answerability.jsonl`) keeps the 23 recovered real failures as
   a false-abstention guard, gated at ≤ 1 miss of 23 with `T2-21` correct as
   a hard requirement (docs/eval.md "Answerability").

## Consequences

- A clean-looking `no such column` error found in a future log must not be
  promoted into "the data doesn't cover this" — that is the exact 0/41
  intuition this record exists to stop.
- Scope diagnosis requires the FM; with Apple Intelligence required
  (ADR 0011) the no-verdict path is transient, and the reason-only failure
  copy is designed to be complete without it.
- The verdict annotates a typed `TurnFailureReason`; it is never a reason
  itself.
