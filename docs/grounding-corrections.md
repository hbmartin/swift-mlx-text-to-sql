# Grounding and correction behavior

The runtime keeps valid query results available while making uncertainty and
degradation explicit. Every generated Candidate Query retains its identity
through generation, execution, repair, grounding, voting, persistence, and
developer rendering.

## Structural and execution defenses

`sql_grammar.ebnf` restricts constrained generation to one read-only SQLite
query over the frozen schema. The database is separately opened read-only
with an authorizer that permits only read operations. A SQLite execution
error triggers at most two identified repair candidates; each repair records
the failed SQL and exact error without overwriting the initial candidate.

## Column-aware Grounding Checks

Grounding is conservative and runs only when a successful query returns no
rows (or a single all-NULL scalar needs a result-shape notice).

- Only string literals in supported `=` and `IN` predicates are considered.
- Qualified columns resolve through declared table aliases.
- An unqualified column resolves only when exactly one source table declares
  it.
- Checks run only for the declared entity/categorical column catalog.
- A literal is compared only with the complete distinct value domain of its
  resolved column. Suggestions therefore come from that same column.
- Findings contain the qualified column, literal, and optional suggestion.

Dates, free-form columns, LIKE patterns, ranges, unresolved columns, and
expression-wrapped predicates are skipped with a typed reason. They never
borrow values from a global cross-column catalog and never produce a
correction claim.

Successful complete value-domain loads are cached per qualified column.
Errors and row-capped partial loads are never cached. A catalog error records
the exact table, column, and error as a Grounding Degradation; the valid query
result is returned, unsupported correction notices are suppressed, and a
later turn retries the load.

## Voting

When voting is configured, every vote contains an executed temperature-zero
Deterministic Anchor. The calibrated portfolio is exactly that anchor plus
`N-1` explicitly identified candidates at the manifest's sample temperature.
If the normal production candidate used a nonzero temperature, it remains in
telemetry but is outside this calibrated portfolio; it is available only for
the visible degraded fallback when the anchor fails and no group wins.
Candidate results are grouped by the shared typed canonical representation:

- INTEGER and REAL share a numeric domain after four-decimal half-even
  normalization.
- TEXT, full BLOB bytes, and NULL remain distinct domains.
- Duplicate rows remain significant; row order and column labels do not.
- Row arity must match, and a truncated result is not a complete Result
  Group member.

A Result Group wins only with more than half of all configured candidates,
including candidates that failed. If no group reaches that threshold, the
complete Deterministic Anchor is selected and the answer shows a concise No
Consensus notice. If the anchor fails or is truncated, a successful primary
result may be retained only with the distinct visible degraded-fallback
notice and telemetry reason. There is no plurality winner or iteration-order
tie-break.

## Telemetry

The immutable `TurnTelemetry` record includes the original and standalone
question, FM and gate decisions, integer-microsecond stage durations, every
candidate request and result, repairs, grounding checks/skips/degradations,
vote trigger/outcome, selected candidate, and selection reason. Candidate
rows are retained to the applicable cap (500 in the app, 10,000 in
evaluation), including explicit truncation status. Chat history, final JSONL,
and developer mode use this same record.

Exported telemetry contains portfolio questions, SQL, and complete result
rows. Treat it as portfolio data and share it only through an approved
channel.
