# Prepared Follow-up Suggestions

Status: accepted.

## Context

Natural follow-ups are central to portfolio exploration, but generating SQL only
after a suggestion is tapped makes a product-authored affordance feel no faster
or safer than arbitrary text. Generating all possible follow-up answers eagerly
would compete with submitted work, could expose stale results after an app or
model update, and would make a partially completed background operation hard to
recover across process termination.

The portfolio database is bundled and read-only. This makes a prepared result
reusable, provided the exact model policy, runtime mode, schema contract,
database bytes, SQL bytes, and result payload remain compatible.

## Decision

After each eligible completed answer, CREG asks the Apple Foundation Model for
exactly three concise, unique, standalone questions. The operation receives only
the latest source question, its standalone interpretation, narration, result
shape and preview, the portfolio as-of date, and the compact schema. SQL and
older conversation turns are never included.

Preparation is best-effort, progressive, and lower priority than user work. It
runs only while no turn is active or queued and is cancelled immediately when a
question is submitted or the app becomes inactive. Switching Conversations does
not cancel it. Each question gets one temperature-zero Candidate Query plus the
existing maximum of two bounded repairs, followed by SQLite validation,
read-only execution, and Grounding Checks. Rewriting, ambiguity gating, voting,
and narration are skipped. Invalid candidates and empty, null, or
literal-mismatch results are rejected; no replacement proposal is requested.

Every accepted Prepared Follow-up stores its SQL and typed result with versioned
provenance: preparation schema and policy versions, model key and revision,
runtime mode, portfolio database SHA-256, SQL SHA-256, and result-payload
SHA-256. One latest batch per Conversation is persisted progressively, including
its source-answer identity, resumable context, and preparing/completed status.
A new submission retires and deletes that batch.

On tap, the engine checks provenance and hashes and prepares the SQL once in
SQLite. A compatible hit emits the cached typed result before grounding or
narration begins and performs neither MLX generation nor SQL execution. The app
persists a provisional Prepared Answer, keeps the Result Viewer available, then
uses the shared inference serializer for grounding and narration and replaces
that same message payload without changing transcript position. Copy, share,
Read Aloud, and feedback remain unavailable while narration is provisional.

If compatibility or validation fails, the displayed question transparently
runs through the Free-form Question pipeline. If narration fails, is stopped,
or the process terminates, the same cached result is retained and the message is
finalized with deterministic fallback narration. Search indexes only the final
narration, never suggestion text, SQL, or cached result values.

Diagnostics contain only timing, rank, rejection reason, hit/miss state, and
tap-to-preview latency. Preparation events and current-batch provenance are
included in JSONL and Support Bundle exports; sanitized diagnostics do not copy
portfolio content.

## Consequences

Prepared chips have a higher up-front compute cost, but that cost is invisible,
cancellable, persisted progressively, and never outranks a user turn. A valid
tap has a structural fast-path guarantee: result visibility requires no model
inference and no query execution. The result is still protected against stale or
tampered cache data, and all mismatch cases preserve correctness by falling back
to the normal pipeline.

The batch is deliberately latest-only. CREG does not promise chips for every
historical answer, and a valid subset smaller than three is expected when
preflight rejects candidates.
