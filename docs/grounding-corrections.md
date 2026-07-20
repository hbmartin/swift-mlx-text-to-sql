# Grounding & correction-layer notes

What guards against wrong answers, layer by layer, and the judgment calls
made while building them.

## Structural layer: grammar-constrained decoding

The grammar (`sql_grammar.ebnf`, generated from the live DB by
`tools/generate_grammar.py`) makes invalid output *unrepresentable*:
SELECT-only; FROM/JOIN targets restricted to the seven real tables plus
CTE names locked to `cte`/`cte0`–`cte9` (so a hallucinated table can never
be a row source); qualified column references restricted to real columns;
SQLite-valid aggregate arities enforced; boolean predicate chains bounded
to prevent degenerate decoding loops; no PRAGMA/ATTACH/multi-statement.

Two deliberate openings, with rationale:

1. **Free string literals.** `'...'` contents are unconstrained — needed for
   LIKE patterns and name matching. Consequence: wrong literals are the top
   remaining silent-failure channel → handled by heuristic layer A below.
   Enumerating low-cardinality values into the *prompt* (schema_prompt.txt
   lists actual values for market/status/type/etc.) is the grounding
   mechanism instead; grammar-level enumeration would add nothing while free
   strings exist.
2. **Bare lowercase identifiers as expressions.** Required so SELECT aliases
   work in ORDER BY / GROUP BY / HAVING (`ORDER BY vacancy`). Validated by
   round-tripping the gold set through the grammar — without this, the
   canonical vacancy query itself was unrepresentable. Consequence: a
   made-up bare identifier compiles but fails at execution → caught by
   layer 2 (self-repair). Qualified references (`p.xxx`) stay fully
   constrained.

Behind the grammar: read-only SQLite connection + `sqlite3_set_authorizer`
denying everything but SELECT/READ/FUNCTION/RECURSIVE plus
TRANSACTION/SAVEPOINT (GRDB wraps reads in transactions; on a read-only
connection these are harmless — discovered when the authorizer's first
version broke `BEGIN DEFERRED TRANSACTION`).

## Layer 2: execution-error self-repair

On SQLite error, re-prompt the same model with the failed SQL + error string,
≤ 2 retries, then graceful failure. Implemented in `QueryPipeline`; exercised
by unit tests (error → repair → success, and triple-failure → give-up).

## Layer A: result-shape + value-grounding heuristics (always on)

`ResultHeuristics` (CREGEngine): on every successful execution —

- **Empty result + unmatched literal** → fuzzy match against an entity
  catalog (property/tenant/fund names, markets, submarkets, cities, lenders,
  appraisers; loaded once from the read-only DB). Containment/prefix match
  first, then edit distance with an acceptance bound of max(2, len/4).
  Produces "Nothing matched 'Kingsly Tower' — did you mean 'Kingsley
  Tower'?" as a notice on the answer.
- **Empty result, literals fine** → "a filter may be too narrow" notice.
- **Single all-NULL row** (degenerate aggregate) → notice.

Literals skipped: dates/numbers/LIKE fragments and short enum-ish strings
(< 3 chars). Notices ride on the answer (`TurnOutcome.answered.notice`) —
per the PRD's product philosophy, show the confident answer and make
correction one tap/turn, don't block.

## Layers C + D: self-consistency voting, uncertainty-gated

Layer C (`QueryPipeline`): sample N−1 extra candidates at temperature 0.7
alongside the greedy one, execute all, cluster by result signature
(order-insensitive multiset of rows, reals rounded to 4dp — identical
normalization to the harness's EX), majority wins; the vote and candidates
are surfaced in developer mode and the event log.

Layer D decides *when* C runs. Design decision for v1 Swift: **deterministic
proxies** — a heuristic-A finding, or a repaired execution, triggers the
vote (or `alwaysVote` for ablation). True token-entropy gating lives in the
Python harness (`run_eval.py` logs per-token pre-mask entropy for every gold
item, correct vs wrong) so the threshold can be chosen empirically; wiring
entropy into the Swift path needs a custom token iterator around
MLXStructured's `GrammarMaskedLogitProcessor` and is deferred until the
harness shows the entropy signal separates correct from wrong answers
(stage-1 data: means are close — 0.19 correct vs 0.14 wrong on the first
config — so the proxy triggers are currently the *better* gate).

## Layer B: narration-as-confirmation

The FM's one-line narration restates what was looked at; the user judges
intent. In place since M2; templated fallback when the FM is unavailable.

## Deferred (v2, per PRD)

Layer E — explicit FM round-trip semantic check (narration vs question
divergence detection).
