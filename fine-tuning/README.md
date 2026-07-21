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
- `tools/run_experiment.py` — one immutable MLX-LM + W&B experiment.
- `tools/evaluate_checkpoints.py` — fixed gold_v1 comparison for every saved
  checkpoint and deterministic development-checkpoint selection.
- `tools/sync_wandb.py` — resumable evidence/table/artifact synchronization.
- `tools/import_wandb_history.py` — read-only mirrors of the two historical
  finalist runs and their evaluations.
- `tests/` — data invariant tests.
- `eval/` (M3) — EX scorer, failure taxonomy, leaderboard, Claude-judge.
- `synth/` (M6) — synthetic training data generation + judge filter.

## W&B experiment campaigns

New training runs require authenticated online W&B logging. `WANDB_API_KEY`
and `WANDB_ENTITY` are required; `WANDB_PROJECT` defaults to `creg-sql`.
Local manifests, inventories, and SHA-256 identities remain canonical. A run
is not eligible for fusion, registration, publication, or finalization while
its manifest status is `awaiting_wandb`.

A local, Git-ignored repository `.envrc` can supply the non-secret
`WANDB_ENTITY=pathlaw` and `WANDB_PROJECT=creg-sql` values. Create it locally
and run `direnv allow` once from the repository root. Keep `WANDB_API_KEY` in
the user environment or a secret manager.

```sh
export WANDB_API_KEY=...

# Short authenticated smoke: 100 training iterations, then all gold_v1 rows.
uv run --frozen python -m tools.run_experiment \
  --model-key qwen25-coder-3b \
  --campaign-id creg-sql-reliability-v2-smoke \
  --iterations 100

# One explicit screening experiment.
uv run --frozen python -m tools.run_experiment \
  --model-key qwen25-coder-3b \
  --campaign-id creg-sql-reliability-v2-qwen25-coder-3b-screening \
  --fine-tune-type dora --trainable-layers all \
  --rank 16 --scale-ratio 2.0 --dropout 0.05 \
  --learning-rate 0.00005 --iterations 600

# Create the two independent 18-run random sweeps.
wandb sweep --entity "$WANDB_ENTITY" --project "${WANDB_PROJECT:-creg-sql}" \
  config/sweeps/qwen25-coder-3b.yaml
wandb sweep --entity "$WANDB_ENTITY" --project "${WANDB_PROJECT:-creg-sql}" \
  config/sweeps/xiyansql-qwencoder-3b.yaml

# Recover a locally complete run after an upload/network failure.
uv run --frozen python -m tools.sync_wandb \
  --training-run ../eval/training-runs/<run-id>

# Mirror the two committed legacy runs without changing their manifests.
uv run --frozen python -m tools.import_wandb_history
```

The sweep files fix seed 424242, 600 iterations, checkpoints every 100,
batch size 4, accumulation 1, prompt masking, a 2,048-token maximum, and a
constant learning rate. They randomize LoRA/DoRA, last-16/all layers, rank,
scale ratio, dropout, and log-uniform learning rate. There is no Hyperband
pruning: selection is post-training execution accuracy.

After both 18-run sweeps, `tools.select_campaign plan-promotions` chooses two
recipes per family and emits the 12-result confirmation plan. Seed 424242 is
reused and only seeds 424240/424241 are newly trained, producing eight extra
runs and 44 training runs total. Use `tools.promote_experiment` on reused
screening runs so W&B receives every promoted checkpoint and the selected
checkpoint is fused. `tools.select_campaign select-winner` compares the four
three-seed recipes using item-clustered gold_v1 EX, valid SQL, worst-tier EX,
p95 latency, and trainable parameter count. Final-test evidence can only be
attached after selection:

```sh
# First attach final evaluation evidence, then publish through the existing
# publication gate, then attach the immutable Hub revision.
uv run --frozen python -m tools.sync_wandb \
  --training-run ../eval/training-runs/<final-run> \
  --final-evaluation ../eval/runs/<gold-v2-run>
uv run --frozen python -m tools.sync_wandb \
  --training-run ../eval/training-runs/<final-run> \
  --publication ../eval/publications/<publication>/publication.json
```

The permanent binding set is a separate release gate. Evaluate its 15 cases
at seeds 0–4 using the selected model/GCD/temperature, then require all 75
checks to pass:

```sh
uv run --frozen python -m eval.run_eval \
  --model-key <winner> --gcd <on-or-off> --temperature <temperature> \
  --seed <0-through-4> --gold ../eval/gold/binding_regressions.jsonl
uv run --frozen python -m tools.analyze_binding_regressions \
  --run ../eval/runs/<seed-0> --run ../eval/runs/<seed-1> \
  --run ../eval/runs/<seed-2> --run ../eval/runs/<seed-3> \
  --run ../eval/runs/<seed-4>
```

`tools.finalize_production` requires that binding analysis alongside the
production selection, schema-v3 bounded-policy calibration, full parity, and
both fresh-verified publication records. It is the only supported transition
to a new verified production manifest. Release model copying then writes a
content-addressed `production-model-receipt.json`; Release startup and bundle
inspection both require it to agree with the manifest and actual SQLModel
bytes.

```sh
uv run --frozen python -m tools.finalize_production \
  --production-analysis ../eval/analyses/<production>/analysis.json \
  --binding-analysis ../eval/analyses/<binding>/analysis.json \
  --consistency-analysis ../eval/analyses/<policy>/analysis.json \
  --parity-analysis ../eval/analyses/<parity>/analysis.json \
  --publication ../eval/publications/<first>/publication.json \
  --publication ../eval/publications/<second>/publication.json
```

`gold_v2` is post-selection evidence only and must never influence sweep,
recipe, checkpoint, or seed selection.
