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

The queue exists only for the current process and is never restored or executed
automatically after termination. A turn that was active when the process ended is
persisted as **Interrupted** and offers **Ask Again** on the next launch. Switching
or background completion never automatically changes the visible Conversation.

## Consequences

The user's current Conversation feels responsive without overlapping models or
interrupting in-flight inference. Selection may reorder pending work, so the
system is intentionally not strict global FIFO; age ordering within the selected
Conversation and the global fallback limit starvation. The UI must expose queued,
active, cancellable, interrupted, completed-in-background, and unread states
without implying that queued work will survive termination.
