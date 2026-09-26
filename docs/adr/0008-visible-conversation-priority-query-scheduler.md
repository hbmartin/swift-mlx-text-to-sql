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

The queue exists only for the current process. A known interruption recorded
by that process may retry once when the scene is active. The retry entry is
built from the interrupted turn's own data — question, submission source, and
persisted user message — so it queues even while its Conversation is offscreen,
ordered by the original question time ahead of later questions in the same
Conversation. The interruption banner owns retry presentation: a queued,
claiming, or releasing retry shows **Retry queued** with a cancel action;
cancelling declines the automatic allowance and keeps the journal row for
**Ask Again**. After process termination, no automatic eligibility is
restored: a persisted **Interrupted** turn offers **Ask Again** and waits for a
tap. Switching or background completion never automatically changes the
visible Conversation.

The interruption journal has one row per turn, keyed by a stable journal ID,
and it is authoritative for the retry count. Each row stores the full
submission source: free form, a Starter Query ID, or the prepared follow-up
payload. Terminal persistence and dismissal close only the corresponding row.
A trailing unanswered user turn is retried in place; when later messages exist,
Ask Again appends a new user turn and transfers the old journal row — and its
spent count — in the same transaction as that user write. Every retry, manual
or automatic, is claimed through the scheduler before inference; the claim
returns the durable count the dispatched turn carries. A successful automatic
claim consumes the single allowed retry; a manual claim preserves whatever
count the row already holds, so Ask Again never replenishes the allowance. A
claim that lands behind a closed gate is released with its kind: an automatic
release restores the unused allowance, a manual release leaves the count alone
and the Ask Again request stays queued until the gate reopens. Every failed
claim restarts the scheduler.

A brief inactive scene closes new dispatch and Apple Intelligence availability
polling only; the active turn and running lower-priority inference continue.
Entering the background interrupts work without a continued-processing GPU
grant and suspends lower-priority inference and model preparation. A granted
task remains open until its terminal history transaction succeeds. Model
preparation journals identify each attempt. A cancelled preparation stays
unfinished until the raw model operation releases the serializer; only then is
its suspension recorded as complete, and a suspension can never reopen an
attempt that already completed. On the next launch, a journal still marked
`suspending` is presented as paused and waits for an explicit Retry tap;
unexpected-interruption reporting is reserved for an attempt that was still
running when the process ended. Cancellation and memory warnings retain the
loaded SQL model container while generation remains gated on successful
preparation. Suspended work resumes after five warning-free seconds, or when
thermal state returns to nominal or fair, after the scene and serializer gates
pass.

Prepared suggestions are owned by a per-Conversation suggestion generation
stored in SQLite. Accepting a question — queued or dispatched — advances the
generation and deletes the prior batch in one transaction before the pipeline
runs. Active turns, parked contexts, and batch writes carry the generation they
began with; the store refuses a batch whose generation changed or whose source
answer is no longer the latest persisted message, and the reducer applies the
same check before parking, resuming, or displaying a context. Whether the Scope
Verdict judge ran is recorded separately from the verdict, so a completed nil
verdict resumes preparation without another judge call and a parked context
that already carries a verdict is never judged again.

A submission whose origin Conversation is missing, deleted, or no longer
selected is saved as the draft of a brand-new Conversation in one transaction,
never into another Conversation's draft. The new chat is selected only if the
user has not navigated elsewhere while it was being created, "saved" is
reported only after the transaction succeeds, and the text is retained for
recovery if it fails.

## Consequences

The user's current Conversation feels responsive without overlapping models or
interrupting in-flight inference. Selection may reorder pending work, so the
system is intentionally not strict global FIFO; age ordering within the selected
Conversation and the global fallback limit starvation. The UI must expose queued,
active, cancellable, interrupted, retry-queued, completed-in-background, and
unread states without implying that queued work will survive termination. A
Conversation never shows chips for an answer that a later accepted question
has already retired, at the cost of one extra SQLite column and a generation
check on every suggestion write.
