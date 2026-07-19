# CREG

A fully offline iOS app that lets a non-technical commercial-real-estate (CRE)
professional explore a portfolio database by asking questions in plain
language. A chat interface takes a natural-language question, an on-device
model converts it to SQL under grammar-constrained decoding, the query runs
against a bundled read-only SQLite database, and the result is shown as a
table with a plain-English summary. Everything — model, data, and inference —
lives on the device.

The product spec is [`CREG — Product Requirements Document.md`](./CREG%20—%20Product%20Requirements%20Document.md).
Domain vocabulary is in [`CONTEXT.md`](./CONTEXT.md). Decisions that would
surprise a future reader are recorded in [`docs/adr/`](./docs/adr/).

## Status

| Milestone | Scope | State |
| --- | --- | --- |
| M0 | Repo hygiene: glossary, ADRs, .gitignore | ✅ done |
| M1 | Schema freeze + seeded database generator + invariant tests | ✅ done |
| M2 | Walking-skeleton app: full pipeline shape + grammar-constrained decoding | ✅ done (compile-verified; on-device smoke run pending) |
| M3 | Gold set stage 1 (~60 triples) + Python eval harness | ⬜ next |
| M4 | Correction layers A–D + developer mode | ⬜ |
| M5 | Gold set → 200, factorial sweep, Swift parity CLI, model selection | ⬜ |
| M6 | Close the fine-tune loop once (synthetic data → LoRA → eval → bundle if it wins) | ⬜ |

"v1 done" = the fine-tune loop has been executed end-to-end at least once,
with the winning model (fine-tuned or not) bundled. The winner is chosen
empirically by the eval harness, never by pre-selection.

## Architecture

Each user turn flows through a strictly sequential pipeline (PRD §7). Two
models are involved — Apple's on-device Foundation Model (FM) for
conversational glue and the bundled MLX SQL specialist for constrained
generation — and they never run concurrently:

```
user message
  → FM: follow-up rewrite (decontextualize into a standalone question)
  → FM: ambiguity gate (dial parked at "always pass through" in v1)
  → MLX: SQL generation under grammar-constrained decoding (XGrammar EBNF)
  → execute on read-only SQLite (+ deny-all-but-SELECT authorizer)
  → on SQLite error: self-repair, ≤2 retries with the error string
  → FM: one-line plain-English narration
  → render: table + narration + collapsible "how I answered" trace
```

A single `InferenceSerializer` actor owns every model call (FM and MLX alike),
so active-inference peak memory is max(FM, bundled), not the sum. One
structured event stream (`PipelineEvent`) drives both the user-visible
thinking trace and the JSONL session logs consumed by the eval harness —
one stream, two consumers, built as data rather than display strings.

### Code layout

```
CREG.xcodeproj            Xcode project (single app target, iOS 26)
CREG/                     App shell: entry point + assets (no logic)
CREGKit/                  Local SPM package
  Sources/CREGEngine/     Inference + pipeline engine — no UI, no TCA
    Models.swift            Core types (QueryResult, GateDecision, TurnOutcome…)
    PipelineEvent.swift     The structured event stream + JSONL encoding
    InferenceSerializer.swift  FIFO non-overlap guarantee for all model calls
    FMClient.swift          FoundationModels rewrite/gate/narrate + fallback
    SQLGenClient.swift      MLX model (resident between turns) + MLXStructured GCD
    DatabaseClient.swift    GRDB read-only + sqlite3 authorizer second defense
    QueryPipeline.swift     The sequential turn pipeline
    Resources/              sql_grammar.ebnf + schema_prompt.txt (generated)
  Sources/CREGFeatures/   TCA reducer + SwiftUI chat surface
    ChatFeature.swift       Reducer, dependency wiring, live dependency graph
    ChatMessage.swift       Transcript model + event→trace-line mapping
    HistoryClient.swift     history.sqlite persistence + JSONL export
    Views/                  Chat, result table, trace, settings, root
  Tests/CREGKitTests/     11 tests: authorizer, serializer, pipeline, feature, grammar
db/
  schema.sql              FROZEN seven-table DDL (input to grammar + training)
  creg.sqlite             Generated portfolio database (committed, regenerable)
fine-tuning/              uv Python project (never bare python/pip)
  tools/generate_db.py    Seeded deterministic data generator
  tools/generate_grammar.py  schema+data → EBNF grammar + schema prompt
  tools/fetch_model.py    Download model weights into models/ (gitignored)
  eval/ex.py              Execution-accuracy scoring core (M3)
  tests/                  12 data-invariant tests + 6 EX tests
docs/adr/                 0001 schema semantics, 0002 MLX-over-CoreML, 0003 hybrid harness
```

`CREGEngine` deliberately has no TCA dependency: the M5 Swift parity CLI links
it to re-score model finalists on the exact production inference stack
(see ADR 0003).

## The data

Seven tables, frozen 2026-07-19 (`db/schema.sql`, ADR 0001): `funds`,
`properties`, `tenants`, `leases`, `property_financials`, `loans`,
`valuations`. Shape choices that matter when reading or writing queries:

- **No units table.** Suite, floor, and leased sqft live on `leases`.
- **Vacancy is canonical as a financials snapshot**: `1 − occupancy_rate`
  from the property's latest Month row — never derived by summing leases.
  The lease-derived figure is only a correction-layer cross-check.
- **`property_financials` contains Month rows only** (the `period_type`
  column allows Quarter/Year but v1 data never uses them), so unfiltered
  aggregates cannot silently double-count.
- **`properties.current_market_value` is THE current value**; `valuations`
  is appraisal history.
- Terminated leases store their actual early-exit date in `expiration_date`;
  Holdover leases have a past `expiration_date` but still occupy their suite.

`tools/generate_db.py` (seed 20260719, AS_OF 2026-07-01, 36-month window)
generates ~2,500 internally consistent rows: 4 funds, 50 properties
(46 Owned, 2 Sold, 1 Under Contract, 1 In Development), 150 tenants,
446 leases across all five statuses, 1,724 monthly financial rows, 46 loans,
130 valuations. Accounting identities hold exactly (NOI = EGI − opex,
EGI = GPR − vacancy loss, occupancy = occupied/rentable sqft, per-suite lease
chains never overlap) and `tests/test_invariants.py` enforces them — if one
fails, the data is wrong, not the test.

## Grammar-constrained decoding

At each decoding step the grammar engine masks tokens that would break the
grammar, so output is valid by construction. The grammar
(`sql_grammar.ebnf`, generated from the live database) guarantees:

- **SELECT-only** — write statements are unrepresentable.
- **Real table names only** in FROM (CTE names are restricted to
  `cte`/`cte0`–`cte9`, so a hallucinated table cannot appear as a source).
- **Real column names only** in qualified references (`p.column`).
- No PRAGMA, no ATTACH, no statement chaining.

Deliberate openings: free-text string literals are allowed (needed for LIKE
patterns; wrong literals are the fuzzy-match heuristic's job, M4), and bare
lowercase identifiers are allowed as expressions so SELECT aliases can be
referenced in ORDER BY/GROUP BY — a misused identifier there becomes a
SQLite error handled by self-repair. Defense in depth behind the grammar:
a read-only connection plus a `sqlite3_set_authorizer` callback that denies
everything but SELECT/READ/FUNCTION/transaction control (tested).

**GCD engine spike outcome** (PRD §9 open question): `MLXGuidedGeneration`
does not exist. The engine is
[petrukha-ivan/mlx-swift-structured](https://github.com/petrukha-ivan/mlx-swift-structured)
(XGrammar compiled into Swift, integrated with MLXLMCommon's token loop via
`GrammarMaskedLogitProcessor` — which also exposes the per-token logits the
M4 entropy gating needs). The grammar is additionally validated in Python
with `xgrammar` against canonical CRE queries (accepted) and hostile inputs
(rejected).

## Running it

Prerequisites: Xcode 26+, an Apple Intelligence-capable iPhone (iPhone 15 Pro
or later) on iOS 26, [`uv`](https://docs.astral.sh/uv/). MLX does not run in
the iOS simulator and FoundationModels needs an Apple Intelligence device, so
the dev loop is on-device.

**App:** open `CREG.xcodeproj`, set your signing team (bundle id is a
placeholder `dev.haroldmartin.CREG`), build to the device. On first launch
the SQL model (`mlx-community/Qwen2.5-Coder-3B-Instruct-4bit`, the skeleton
placeholder — the harness re-decides later) downloads from Hugging Face
(~1.7 GB, one-time, needs network). For a fully offline build:
`uv run python tools/fetch_model.py`, then add the downloaded folder to the
CREG target as a folder reference named `SQLModel` — the app prefers it over
the network path. If the FM is unavailable on device, the pipeline degrades
gracefully: no rewrite/gate, templated narration.

Smoke test on device: "Which properties have the highest vacancy?",
"What's my rent roll by property type?", "Which leases expire in the next
12 months?", one follow-up ("now just Office"), one ambiguous question. Check
the trace under each answer, toggle Developer mode in Settings to see the
SQL, and export session logs (JSONL) from Settings.

**Tests and tooling:**

```sh
# Swift: engine + feature tests (macOS host)
cd CREGKit && swift test

# Python: data invariants + EX scorer
cd fine-tuning && uv run pytest

# Regenerate database / grammar (schema is frozen — see ADR 0001 before touching)
cd fine-tuning && uv run python tools/generate_db.py && uv run python tools/generate_grammar.py

# Headless app build (plugin/macro validation must be skipped for mlx-swift)
xcodebuild -project CREG.xcodeproj -scheme CREG -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
```

## Next steps

**M3 — Gold set stage 1 + Python harness.** Draft ~60
(question → gold SQL → gold result) triples covering all seven tables and
all difficulty tiers (single-table filters → joins → windowed/nested), plus
fuzzy-entity, ambiguous, and multi-turn cases. Pipeline per plan decision 12:
Claude drafts → every query machine-executed against `creg.sqlite` → Claude
Opus judges alignment → **the user signs off on 100% of triples**. Stored as
JSONL in `eval/gold/`, strictly held out from training. Harness in
`fine-tuning/eval/`: generation via `mlx_lm` (with optional xgrammar
constraint for GCD-on/off ablation), EX scoring (`ex.py`, already landed),
valid-SQL rate, latency, failure-taxonomy buckets (wrong join / aggregation /
filter / literal / empty-when-expected / timeout), leaderboard emission.
First sweep over the PRD Appendix A candidates.

**M4 — Correction layers + developer mode.** (A) result-shape +
value-grounding heuristics: 0-rows-when-expected, scalar-vs-list shape,
fuzzy-match unmatched literals against actual column values ("nothing matched
'Tower A' — did you mean 'Tower One'?"); (B) narration-as-confirmation is
already in place; (C) self-consistency voting: 3–5 samples, execute all,
cluster by result-set equivalence; (D) uncertainty gating: token entropy from
the logit processor triggers C only when the model is unsure. Developer mode
grows to show the rewrite, gate decision, candidate SQLs + votes, execution
metadata, and per-stage latency/tok-s.

**M5 — Selection.** Gold set → ~200. Full factorial sweep per PRD §12
(model × quantization × base-vs-tuned × GCD on/off × schema serialization ×
self-consistency N). Build `creg-eval-cli` (SPM executable linking
`CREGEngine`) and re-score the top 2–3 configs on the exact production stack
before declaring a winner (ADR 0003).

**M6 — Close the fine-tune loop.** Synthetic data per PRD §13
(schema-grounded templating seeded with real values, pattern transfer from
Spider/BIRD/etc., conversational augmentation, paraphrase, Claude-as-judge
quality gate with logged scores) → LoRA/QLoRA via `mlx-lm` → fuse → 4-bit
quantize → eval on gold → bundle only if it beats the best off-the-shelf
model. Read the failure taxonomy, document next-iteration priorities.
That closes v1.

Deliberately open until the harness decides: the EX "good enough" threshold,
self-consistency N and the entropy threshold, ambiguity-gate default
sensitivity, and MLX resident-vs-unload behavior under memory pressure
(measure on device).
