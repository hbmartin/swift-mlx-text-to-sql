# CREG v1 — A Walkthrough for Junior Engineers

A plain-language tour of what this project does, the reasoning behind every
major decision, what the experiments showed, and the lessons that transfer
to other projects. The formal record lives in
[`final-report.md`](./final-report.md) and its companion docs; this is the
whiteboard version.

## The problem we're solving

A real-estate executive wants to ask their portfolio questions like "which
buildings are the emptiest?" They can't write SQL, and for privacy reasons
nothing can leave their phone. So we need: natural-language question → SQL
→ run it → show a table and a one-line summary, entirely on-device with a
small (≤4B parameter) local model.

Small models are mediocre at SQL in general. Our entire strategy comes from
one observation: **we don't need general SQL — we have exactly one database
with seven known tables.** Every design choice below is about exploiting
that.

## The architecture: two models, strict lanes

Each question flows through a fixed pipeline. Apple's built-in Foundation
Model (free, ships with iOS) does the "language chores": rewriting
follow-ups like "now just last year" into self-contained questions,
deciding if a question is too ambiguous, and writing the friendly summary
at the end. Our bundled model does exactly one thing: standalone question
→ SQL. Narrow jobs are what small models are good at.

One subtlety worth internalizing: the two models **never run at the same
time**. A single Swift `actor` (the `InferenceSerializer`) owns every model
call. Why? Memory. If both models could be mid-inference simultaneously,
peak RAM is the *sum* of both; serialized, it's the *max*. On a phone,
that's the difference between working and being killed by the OS. Fun Swift
detail: actors are *reentrant* — a naive `await` inside an actor method
lets other calls interleave — so the serializer chains each operation onto
the previous one's completion instead.

## Grammar-constrained decoding, the load-bearing trick

An LLM generates one token at a time by picking from a probability
distribution. **Grammar-constrained decoding (GCD)** means: before each
pick, mask out (set to −∞) every token that would violate a grammar you
supply. The model literally *cannot* produce invalid output.

We generate that grammar *from our actual database*: only `SELECT` exists
(writes are unrepresentable — a security guarantee, not just a quality
one), only our seven real table names can appear after `FROM`, only real
column names in qualified references. A hallucinated table like
`rent_payments` isn't "unlikely" — it's impossible.

Two places we deliberately left the grammar loose, and both taught us
something:

- **String literals are free-form** (you need `LIKE '%Tower%'`). So a
  misspelled property name produces valid SQL that matches zero rows — the
  top *silent* failure mode. That's handled downstream by the correction
  layers.
- **Bare identifiers are allowed** so `ORDER BY vacancy` can reference a
  SELECT alias. This was found by *round-tripping the gold answers through
  the grammar* — the canonical vacancy query was rejected by our own
  grammar. Lesson: always validate your gold set against your constraints;
  the test runs in both directions.

And the big empirical surprise: **GCD is not free for weak models.** Our
1.5B candidate, when constrained, got trapped generating
`TOTAL(TOTAL(TOTAL(...` until the token limit — the mask kept removing what
it wanted to say, and it spiraled. The PRD had warned about a "hidden cost
of structure"; we watched it happen. Meanwhile for our final fine-tuned
model, GCD cost exactly zero accuracy — it had internalized the grammar, so
the constraint only ever removed tokens it wasn't going to pick anyway.
Takeaway: treat GCD on/off as a *per-model* experiment, never a global
assumption.

## The data: fake, but rigorously fake

We generated the portfolio database ourselves, and the crucial property
isn't realism — it's **internal consistency**. If `occupancy_rate` doesn't
equal leased-square-feet ÷ rentable-square-feet, then our own sanity-check
heuristics would fire on every honest answer, and our "correct" gold
results would be incoherent. So the generator builds *lease timelines per
suite* first (no two leases can overlap in the same suite), then derives
monthly financials from those leases, then derives loan coverage ratios
from those financials. Everything downstream of everything. Twelve tests
enforce identities like `NOI = EGI − opex` to the cent, written with the
attitude: "if this fails, the *data* is wrong, not the test."

Also everything is seeded — same seed, byte-identical database. When your
eval scores wobble, you want zero suspicion pointed at your data.

## How we measure: gold sets and EX

A **gold set** is a list of (question, correct SQL) pairs. The metric is
**execution accuracy (EX)**: run the model's SQL and the gold SQL, compare
*result sets* (order-insensitive, floats rounded). This forgives cosmetic
differences — `ORDER BY name` vs `ORDER BY name DESC` over the same rows
both pass — while catching real wrongness.

The subtle part is that many questions don't have one "correct" answer
until you *decide* things: does "rent roll" include holdover tenants who
stayed past lease expiry? (We said yes.) Is "vacancy" computed from leases
or from the reported occupancy number? (Reported, latest month.) These
conventions were written down as an ADR and baked into the prompt, the gold
set, and the training data *identically*. That consistency is most of the
game.

## The experiments, honestly

Four candidate models, all 4-bit, GCD on and off, 60 questions
(stage 1, full tables in [`model-selection.md`](./model-selection.md)):

| candidate | best EX |
|---|---|
| Qwen2.5-Coder-3B (general coding model) | **0.356** |
| XiYanSQL-3B (*specifically fine-tuned for text-to-SQL*) | 0.322 |
| Qwen2.5-Coder-1.5B / Qwen3-1.7B | 0.18–0.23 |

The SQL-specialist losing is a great lesson: it learned *other databases'*
conventions. Generic SQL skill ≠ knowing that in *this* schema "current
value" lives on `properties.current_market_value`, not in the valuations
table. The failure buckets confirmed it: models were fine at mechanical
single-table SQL and consistently wrong about *our semantics*.

That's exactly the gap fine-tuning targets. **LoRA** (the technique used)
doesn't retrain the whole model; it learns small low-rank "adjustment"
matrices on top of frozen weights — cheap enough to run on a laptop in
~90 minutes. We generated 1,424 training pairs from templates over real
entities, gated each one (must execute, must be grammar-legal, must not
appear in the gold set — never train on your exam), trained, and
re-evaluated on a harder 200-question gold set:

**Base model: 0.226. Fine-tuned: 0.663.** Tier-2 (the semantics-heavy
questions) went from 0.18 to 0.70.

Now the part to absorb most carefully. Splitting that 200 into the 140
template-generated questions and the 60 hand-written ones:

| slice | base | fine-tuned |
|---|---|---|
| template-family questions (140) | 0.071 | **0.786** |
| novel hand-written SQL-scored phrasings (59) | 0.356 | 0.373 |

The model *mastered the semantics as expressed by the templates* and
generalized weakly beyond them. Training loss had dropped to 0.001 — that
number alone should make you say "memorization." The fix for round two
isn't more data, it's more *linguistic diversity* — having a big model
paraphrase each question ten ways at dev time. Always decompose your metric
before celebrating it; the aggregate "+44 points!" and the decomposition
tell very different stories, and both are true.

## Defense in depth for wrong answers

Since GCD guarantees structure but not meaning, there's a stack of cheap
corrections (details in [`grounding-corrections.md`](./grounding-corrections.md)):

- SQLite error → feed the error back to the model and retry (≤2×).
- Empty result + a literal that matches no known entity → fuzzy-match and
  suggest: "did you mean 'Kingsley Tower'?"
- Uncertainty signals → generate 3 candidates and let their *results* vote.

For "when is the model uncertain," the harness logs per-token entropy —
and for the fine-tuned model, correct answers average 0.017 vs 0.066 for
wrong ones, a clean 4× separation. That number turns "maybe use entropy
someday" into "threshold at ~0.03." The philosophy throughout: this is
read-only exploration — show a confident answer and make correction one
tap, don't block the user with verification theater.

## Unglamorous things that ate real time

Worth knowing because this is what the job actually feels like:

- A library the plan named (`MLXGuidedGeneration`) simply didn't exist —
  an hour of checking beat a day of assuming.
- A tokenizer leaked `<|im_end|>` into decoded text and silently zeroed a
  model's scores — the tell was a *too-clean* 0.000, and the rule is: a
  score of exactly zero is a bug until proven otherwise.
- Background shells had a minimal PATH and a different working directory,
  which broke pipelines in three different ways before standardizing on
  absolute paths + explicit `cd`.
- Swift Package Manager builds of MLX lack the compiled Metal shaders that
  Xcode builds produce — the parity CLI had to be built through
  `xcodebuild`.

None of this is in any textbook; all of it is half the work.

## Where it landed

A fully offline iPhone app — 1.7 GB with model and database bundled — that
answers portfolio questions at 0.663 EX single-shot *before* the correction
layers add their lift at runtime, with a Swift-vs-Python parity check
agreeing on 59/60 items (always verify your lab harness matches production
— ours did, but "surely it's the same" is not evidence).

## One-sentence takeaways

1. Narrow the model's job until a small model can do it.
2. Make invalid outputs impossible rather than unlikely.
3. Decide your semantic conventions once and encode them everywhere
   identically.
4. Measure with held-out data — and then decompose the metric.
5. When a result looks either perfect or like garbage, suspect the harness
   before the model.
