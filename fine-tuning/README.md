# CREG Python tooling

The `uv` project holding data generation, the eval harness, synthetic-data
tooling, and the LoRA fine-tuning loop. Always run through `uv`, never bare
python/pip.

## Commands

```sh
# Regenerate the bundled portfolio database (deterministic, seeded)
uv run python tools/generate_db.py

# Regenerate the SQL grammar + schema prompt from the database
# (run after any schema change — but the schema is frozen; see docs/adr/0001)
uv run python tools/generate_grammar.py

# Invariant tests for the generated data
uv run pytest

# Download SQL-model weights into ../models/ (gitignored)
uv run python tools/fetch_model.py
```

## Layout

- `tools/generate_db.py` — seeded generator for `db/creg.sqlite`; enforces the
  accounting invariants the correction heuristics rely on.
- `tools/generate_grammar.py` — emits `sql_grammar.ebnf` (XGrammar EBNF,
  SELECT-only, schema identifiers as terminals) and `schema_prompt.txt`
  (compact schema serialization with enumerated low-cardinality values) into
  `CREGKit/Sources/CREGEngine/Resources/`.
- `tools/fetch_model.py` — snapshot-downloads candidate models.
- `tests/` — data invariant tests.
- `eval/` (M3) — EX scorer, failure taxonomy, leaderboard, Claude-judge.
- `synth/` (M6) — synthetic training data generation + judge filter.
