# Prioritize the visible conversation in the global query scheduler

Status: accepted.

## Context

CREG has one inference pipeline because Apple Foundation Models and the bundled
MLX model must never overlap. Multiple Conversations still need to accept
questions while an answer is running, and the user may switch Conversations
before that answer completes. Strict global FIFO is predictable but can make the
Conversation the user is actively viewing wait behind unrelated queued work.

## Decision

At most one query is active globally, and active work is non-preemptive. Later
submissions become visible, cancellable Queued Questions. After active work
finishes, the scheduler dispatches the oldest Queued Question in the currently
visible Conversation; if it has none, it dispatches the globally oldest remaining
Queued Question. A question receives its Conversation's latest completed history
when dispatch begins.

The queue exists only for the current process. A known interruption in that
process may retry once when the scene returns to the foreground, ordered by the
original question time ahead of later questions in the same Conversation. The
interruption banner owns retry presentation. After process termination, no
automatic eligibility is restored: a persisted **Interrupted** turn offers
**Ask Again** and waits for a tap. Switching or background completion never
automatically changes the visible Conversation.

The interruption journal has one row per turn, keyed by a stable journal ID.
Each row stores the full submission source: free form, a Starter Query ID, or
the prepared follow-up payload. Terminal persistence and dismissal close only
the corresponding row. A trailing unanswered user turn is retried in place;
when later messages exist, Ask Again appends a new user turn and transfers the
old journal row in the same transaction as that user write. A busy scheduler
queues the retry without changing its journal until dispatch. The trailing
retry is claimed before inference, so a crash cannot trigger a second automatic
retry. Legacy rows with no typed source remain free form.

A scene becoming inactive immediately interrupts work without a
continued-processing GPU grant and suspends lower-priority inference. The
background event uses the same idempotent deactivation path. A
granted task remains open until its terminal history transaction succeeds.
Model preparation journals identify each attempt. A cancelled preparation stays
unfinished until the raw model operation releases the serializer; only then is
its suspension recorded as complete. A process death during that drain is
reported on the next launch. Cancellation and memory warnings retain the loaded
SQL model container while generation remains gated on successful preparation.
Suspended work resumes after five warning-free seconds, or when thermal
state returns to nominal or fair, after the scene and serializer gates pass.

## Consequences

The user's current Conversation feels responsive without overlapping models or
interrupting in-flight inference. Selection may reorder pending work, so the
system is intentionally not strict global FIFO; age ordering within the selected
Conversation and the global fallback limit starvation. The UI must expose queued,
active, cancellable, interrupted, completed-in-background, and unread states
without implying that queued work will survive termination.
