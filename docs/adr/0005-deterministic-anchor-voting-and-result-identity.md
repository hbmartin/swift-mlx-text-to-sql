# Deterministic-anchor voting and typed result identity

Status: accepted.

## Context

SQL text is the wrong identity for voting: different queries can return the
same answer. Swift `Hasher` is also process-random, and dictionary iteration
cannot choose a stable tie winner. The former result comparison collapsed
SQLite types, represented BLOBs by byte count, and could silently treat a
row-capped prefix as complete. Those behaviors make Python EX, Swift EX,
runtime voting, and persisted telemetry disagree.

Plurality voting creates a second ambiguity. With three all-different results,
choosing whichever group appears first looks like consensus even though no
result has majority support.

## Decision

Python and Swift use one conceptual canonical result representation:

- INTEGER and REAL share a numeric domain after four-decimal, half-even
  normalization;
- the numeric canonical form is total over every double: any finite value
  renders as a plain quantized decimal (including magnitudes past 1e24),
  negative zero is `0`, and non-finite REALs — which SQLite can produce,
  for example from `SELECT 9e999` — render as `nan`, `inf`, and `-inf`;
- TEXT never equals a display-identical number;
- TEXT identity, hashing, and ordering are Unicode code-point based, so NFC
  and NFD spellings of one grapheme are distinct values, exactly as Python
  compares `str`;
- BLOB identity is the complete byte sequence;
- NULL is its own domain;
- duplicate rows and row arity are significant;
- row order and column labels are outside EX; and
- a truncated result is incomplete and cannot join a Result Group.

Canonical typed rows are deterministically sorted and JSON encoded. Persisted
Result Group IDs are SHA-256 of those bytes. Shared golden fixtures pin both
the encoding and match decision in Python and Swift.

Every runtime vote includes an executed temperature-zero Deterministic
Anchor. The calibrated vote portfolio is the anchor plus `N-1` candidates at
the configured sample temperature. A nonzero-temperature production
candidate is retained in telemetry but does not replace one of those
calibrated candidates. A Result Group wins only when it contains more than
half of all configured Candidate Queries; failed and truncated candidates
still count in the denominator. There is no plurality winner.

Empty results carry no consensus evidence. Every empty result shares one
digest regardless of the query that produced it, so two wrong queries that
each matched nothing would otherwise outvote a correct anchor. Empty
candidates count in the denominator but never form or join a majority; an
empty anchor remains deliverable through the No Consensus path.

If no group has a strict majority, the executed, complete anchor is selected
and the answer carries a visible No Consensus notice. If the anchor fails or
is truncated, the successful primary may be retained only as the distinct
degraded anchor-failure outcome and notice. Candidate IDs, roles, seeds,
results, digests, vote outcome, and selection reason are retained in
`TurnTelemetry`.

## Consequences

Replays and exports have stable Result Group identities, and the app and both
evaluation harnesses measure the same thing. Voting may deliberately fall
back even when two successful candidates differ and a third fails; this is
the cost of describing uncertainty honestly. Full BLOB retention and typed
rows make telemetry more sensitive and larger, so the 500-row app cap,
10,000-row evaluation cap, truncation bit, and portfolio-data export warning
are mandatory.
