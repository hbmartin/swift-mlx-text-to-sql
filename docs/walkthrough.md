# CREG walkthrough for junior engineers

This is the whiteboard version of the project: what CREG does, why the
architecture looks this way, what the experiments actually proved, and where
the sharp edges remain. The formal record is `docs/final-report.md`.

## The problem

A commercial-real-estate professional wants to ask questions such as “which
properties are the emptiest?” without writing SQL or sending portfolio data
to a remote inference service.

CREG turns a natural-language question into one read-only SQLite query over a
fixed seven-table portfolio. It executes that query locally and shows both the
rows and a short narration. The fixed schema is the key constraint: the model
does not need to understand every database, only this database and its
documented business meanings.

## The pipeline

One turn moves through:

```text
question
  → standalone rewrite
  → ambiguity gate
  → SQL generation
  → read-only execution
  → bounded repair
  → column-aware grounding
  → result voting
  → narration
```

Apple Foundation Models handle language-facing steps such as rewriting a
follow-up and narration. The pinned MLX model handles SQL. An
`InferenceSerializer` prevents these inference workloads from overlapping,
which bounds peak memory. That serializer must do more than put methods on a
Swift actor: actors are reentrant across `await`, so operations explicitly
chain to the previous completion.

Every SQL attempt is a `Candidate Query` with a stable ID and explicit role.
Initial generation, repairs, the deterministic anchor, and consistency
samples cannot overwrite one another in telemetry.

## Structure is constrained twice

Grammar-constrained decoding masks tokens that would violate the SQL grammar.
The grammar exposes `SELECT`, the real tables, and schema-aware column
references. It sharply reduces structurally impossible output, but it cannot
guarantee that a syntactically valid query answers the question.

SQLite is also opened read-only with an authorizer. The grammar is a
generation constraint; the database authorizer is the enforcement boundary.
Defense in depth matters because unconstrained repair text, future grammar
changes, or runtime bugs must not turn into writes.

The evaluation found that GCD is not universally helpful. On gold_v1,
Qwen2.5-Coder-3B improved from 33.33% to 35.00% EX with GCD, while the other
three base families lost accuracy and often paid much higher latency. After
fine-tuning, both finalists selected GCD on. The practical lesson is to test
constraints per artifact instead of treating them as a global quality switch.

## Result equality is a domain decision

Comparing SQL strings is too strict: different SQL can return the same answer.
Converting every SQLite value to display text is too loose: numeric `1` and
text `"1"` are not the same value.

CREG uses typed execution identity:

- INTEGER and REAL share a numeric domain after four-decimal, half-even
  normalization;
- TEXT, complete BLOB bytes, and NULL remain distinct;
- duplicate rows count and row arity must match;
- row order and column labels do not affect EX; and
- a row-capped result is incomplete, never silently equal.

Canonical rows are sorted, deterministically JSON-encoded, and identified by
SHA-256. Python EX, Swift EX, and runtime Result Groups use shared golden
fixtures. This is why nine parity differences could safely be classified as
equivalent: their generated SQL whitespace differed, but the complete typed
digests matched.

## Voting means majority, not “most votes”

With three different results, each has one vote. Picking whichever dictionary
entry appears first is not consensus; it is an accidental tie-break.

Every CREG vote now contains one executed temperature-zero Deterministic
Anchor and two sampled candidates. A Result Group wins only with more than
half of all configured candidates. Failed and truncated candidates still
count in the denominator.

If no group has a majority, the complete anchor is shown with a visible No
Consensus notice. If the anchor fails or is truncated, a successful primary
can survive only under a separate visible degraded-fallback reason. This
contract makes uncertainty honest and replayable.

Calibration tried sample temperatures 0.1, 0.3, and 0.7 on all 200 gold_v2
items for five trial seeds:

| Sample temperature | EX | Valid SQL | No Consensus | p95 latency |
|---:|---:|---:|---:|---:|
| 0.1 | 65.60% | 93.60% | 2 / 1,000 | 9.178 s |
| 0.3 | 65.80% | 93.80% | 13 / 1,000 | 9.441 s |
| **0.7** | **66.80%** | **95.40%** | 40 / 1,000 | 9.158 s |

Temperature 0.7 won for sample roles. Normal production generation remains
deterministic at temperature 0.0. Separating these roles prevents a useful
diversity temperature from making every ordinary replay nondeterministic.

## Grounding is about columns, not loose strings

An earlier style of correction can collect every literal and compare it with
one global bag of known values. That can suggest a tenant for a property name
or “correct” a date as if it were a category.

CREG instead resolves supported `=` and `IN` literals to one unambiguous
column. It checks only declared entity/categorical domains and suggests only
from the same column. Dates, free-form text, LIKE patterns, ranges, wrapped
expressions, and ambiguous bindings receive typed skip reasons.

Complete successful catalogs cache by qualified column. Failed or row-capped
loads never cache. A catalog failure does not discard a valid query result:
the app records the table, column, and exact error, suppresses any unsupported
correction claim, and retries on a later turn.

## Reproducibility begins before evaluation

A repository name is mutable, and “the model in my cache” is not provenance.
The versioned model manifest pins:

- the repository and 40-character revision;
- every expected file, size, SHA-256, and directory digest;
- source format and complete conversion settings;
- quantization and local materialization name;
- license files and distribution requirements; and
- training/publication provenance for derivatives.

The fetcher supports all artifacts, one named artifact, or the verified
production artifact. It rejects floating revisions and keeps weights out of
Git.

Every evaluation cell writes a new immutable directory. Its manifest records
the command, Git state, machine/runtime versions, lock hashes, every frozen
input hash, and generation settings. Per-item JSONL holds SQL, typed rows,
failures, entropy, seeds, and integer-microsecond timings. If a run is reused
for another analysis, the whole compatibility contract is checked first.

The old PR #1 output could not meet that contract because its original
fine-tuned artifact, seed, and complete training configuration were missing.
It is preserved under `incomplete-provenance`, which is useful history but not
reproducible evidence.

## The model experiments

All four pinned bases ran gold_v1 with GCD on and off:

| Base family | Best EX | Best GCD |
|---|---:|:---:|
| Qwen2.5-Coder-3B | 35.00% | on |
| XiYanSQL-QwenCoder-3B | 31.67% | off |
| Qwen2.5-Coder-1.5B | 23.33% | off |
| Qwen3-1.7B | 20.00% | off |

The top two families received identical training: the same byte-reproduced
1,424-example corpus, seed 424242, 600 iterations, batch size 4, 16 adapted
layers, learning rate `1e-4`, and prompt masking.

Validation loss reached its minimum at iteration 400 for both jobs and rose
again by 600. That is an overfitting warning. The approved comparison
specified one identical 600-iteration run, so both final checkpoints were
fused and held-out execution chose between them. Training loss never selected
production.

On all 200 gold_v2 items:

| Artifact | Selected GCD | EX | Valid SQL |
|---|:---:|---:|---:|
| Qwen base | off | 22.00% | 76.00% |
| XiYan base | off | 28.50% | 88.00% |
| Qwen fine-tune | on | 52.50% | 89.50% |
| **XiYan fine-tune** | **on** | **65.50%** | **93.00%** |

The XiYan fine-tune beat the Qwen fine-tune by 13.0 EX points with a paired
95% interval of [+6.5, +19.5]. This is a held-out execution result, not an
inference from loss.

Temperature experiments tested 0.0, 0.1, 0.3, and 0.7 with seeds 0–4 for all
four artifacts. A nonzero temperature needed at least a two-point mean EX
gain and a paired interval excluding zero. None qualified, so single-shot
production remains temperature 0.

## Publication and licenses

Both fine-tunes were published to public Hugging Face repositories. The
publisher staged model cards and license files, resolved the returned commit,
downloaded into a fresh directory, and compared every byte before updating
the manifest.

The winning XiYan lineage identifies Qwen2.5-Coder-3B. CREG conservatively
inherits the Qwen Research License alongside XiYan's Apache text. The winner
therefore ships `LICENSE`, `QWEN_LICENSE`, and `NOTICE` and is explicitly
non-commercial. License metadata is part of the verified model artifact, not
a link added later to documentation.

## Python and Swift must agree

Python is efficient for broad experiment matrices; Swift is the production
runtime. The final configuration must pass both on all 200 gold_v2 items:

| Harness | EX | Valid SQL |
|---|---:|---:|
| Python | 65.50% | 93.00% |
| Swift | 65.00% | 92.00% |

The absolute drifts—0.50 and 1.00 points—pass the two-point limits. All 14
differing items are explained in `docs/parity-report.md`.

One is especially instructive: both runtimes generated identical malformed
correlated SQL. Python's SQLite 3.53.3 accepted it; Swift's system SQLite
3.43.2 rejected it. Same model input and same SQL do not guarantee the same
execution when database engines differ. Persist runtime versions.

The host CLI also cannot be trusted from a plain `swift run`: SwiftPM did not
package MLX's default Metal library. It is built through Xcode Release, which
includes the required Metal resources. Tooling paths are part of
reproducibility.

## Release packaging

The project no longer points at a static `models/SQLModel`.

- A clean-cache Debug build succeeds with the exact manifest and no bundled
  model; the runtime follows the documented first-use pinned download path.
- A clean-cache Release build downloads or reuses the exact public snapshot,
  verifies it, and bundles it as `SQLModel`.

The final Release inspector matched the embedded and source manifest SHA-256,
all 12 model files, the 1,747,812,702-byte tree, both licenses, and the notice.
That closes the chain from evaluation result to bytes inside the application.

## What telemetry is for

`TurnTelemetry` is one immutable record shared by developer mode, history,
and JSONL export. It includes both forms of the question, rewrite/gate
decisions, each candidate and repair, generation/execution timing, rows and
truncation, grounding, vote outcome, and selection reason.

Persisted durations are integer microseconds; presentation converts to
milliseconds or seconds. Candidate rows are retained to 500 in the app and
10,000 during evaluation. Exports include portfolio questions, SQL, and full
rows, so they must be treated as portfolio data even though the bundled demo
database is synthetic.

## What remains

This work verifies the approved engineering and research chain; it does not
make the prototype a finished financial product. The next real investigations
are:

1. physical iPhone memory, thermal, energy, and end-to-end latency testing;
2. more linguistically diverse training data to reduce template overfitting;
3. generation or validation that rejects SQLite-version-sensitive correlated
   aliases; and
4. a fresh full evidence chain for any model, prompt, schema, grammar,
   tokenizer, database, runtime, or gold-set change.

## Transferable lessons

1. Define result identity before trusting accuracy or voting.
2. Pin bytes, not repository names.
3. Keep evaluation cells immutable and make reuse prove compatibility.
4. Test grammar constraints and temperatures per artifact.
5. Use training loss to diagnose training, not to select production.
6. Treat plurality, failure, truncation, and No Consensus as different states.
7. Persist runtime and database-engine versions.
8. Inspect the final application bundle; a correct cache is not evidence of
   correct packaging.
