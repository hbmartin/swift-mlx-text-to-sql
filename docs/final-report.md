# PR #1 follow-up final report

Status: **complete for the approved reproducibility, correctness, telemetry,
evaluation, fine-tuning, publication, parity, build, and documentation
scope**.

## Outcome

The earlier model-selection claim has been replaced with a complete,
content-addressed evidence chain. The verified production artifact is:

- model: `ft-xiyansql-qwencoder-3b`;
- repository:
  `hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit`;
- revision: `7f97a54819b9329338a5353266d6d2a1294eb341`;
- quantization: MLX affine 4-bit, group size 64;
- generation: GCD on, temperature 0.0, top-p 1.0, top-k disabled,
  512-token cap; and
- voting: always vote, N=3, one deterministic anchor plus two
  temperature-0.7 samples.

The public model is
[available at its immutable Hub commit](https://huggingface.co/hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit/tree/7f97a54819b9329338a5353266d6d2a1294eb341).
Because its lineage includes Qwen2.5-Coder-3B, CREG treats it as
non-commercial and distributes both upstream license texts, a modification
notice, attribution, “Built/Improved using Qwen,” and the explicit
non-commercial warning.

## Evidence summary

| Gate | Result | Evidence |
|---|---|---|
| Four-family screen | Qwen 3B and XiYan 3B selected for training | `screen-c73e14c5f7b91c79` |
| Identical QLoRA jobs | Both 600-iteration runs complete and loadable | `eval/training-runs/` |
| Public finalist verification | Both snapshots fresh-downloaded and exact | `eval/publications/` |
| Temperature standardization | Temperature 0 retained for all four artifacts | four `temperature-*` analyses |
| Production selection | XiYan fine-tune, 65.50% EX / 93.00% valid SQL | `production-cddac7c992c20eae` |
| N=3 calibration | Sample T=0.7, 66.80% EX / 95.40% valid SQL (schema_version 1 policy; see `docs/self-consistency-report.md`) | `consistency-926c85c7ebc25eae` |
| Full Swift parity | 0.50 EX-point and 1.00 valid-SQL-point drift | `parity-cda177e757fbb0b6` |
| Python tests | 62 passed | `uv run --frozen pytest` |
| Swift tests | 42 passed | `swift test` |
| No-cache Debug | Manifest only; runtime-download path | `debug-no-cache-20260721` |
| Clean-cache Release | Exact 12-file, 1.747 GB model bundled | `release-xiyansql-qwencoder-3b-7f97a548` |

Analysis identifiers name directories under `eval/analyses/`; build
identifiers name directories under `eval/build-verification/`.

## Reproducibility and artifact identity

`model-manifest.json` is now the source of truth for acquisition, evaluation,
publication, Xcode packaging, runtime loading, and telemetry. It pins the four
requested upstream revisions, both public derivatives, conversion settings,
quantization, licenses, complete file inventories, SHA-256 values, and
directory digests. Floating revisions are rejected.

The one-model fetch path was replaced by manifest-driven `--all`, `--model`,
and `--production` modes. XiYan conversion declares every option and records
both source and converted-tree identity. Weights remain outside Git.

Every Evaluation Run is immutable and non-overwriting. Its manifest records
the canonical command, Git and dirty state, environment and dependency
versions, lockfile hashes, model/tokenizer/prompt/grammar/schema/database/
gold/artifact hashes, generation settings, and derived-model provenance.
Every item records typed rows, SQL, errors, failure bucket, entropy, token
metrics, truncation, and integer-microsecond timings.

The merged PR #1 outputs are preserved only at
`eval/runs/legacy-pr1-merged/` with `incomplete-provenance`. Its manifest
states that the original fine-tuned artifact, seed, and complete training
configuration are unavailable. No current claim depends on it.

## Training and publication

The synthetic corpus was regenerated before each job and required
byte-for-byte equality. Gold_v2 remained fully held out. Both selected base
families used the same complete QLoRA YAML: seed 424242, 600 iterations,
batch size 4, 16 adapted layers, learning rate `1e-4`, prompt masking, and
all mlx-lm defaults explicit.

The jobs ran for 1:05:18 (Qwen) and 1:08:48 (XiYan), fused successfully, kept
4-bit quantization, and loaded through `mlx_lm.load`. Validation loss was
lowest at iteration 400 and regressed by 600 for both families; this visible
overfitting signal is documented. The approved experiment used the identical
final-600 checkpoint, and held-out execution—not training loss—selected the
winner.

Both finalists were published under the requested `hbmartin/creg-sql-…`
names. The publisher created model cards with full configuration and
provenance, resolved immutable Hub commits, forced fresh downloads, and
compared every file before registration.

## Evaluation findings

The four-family gold_v1 screen selected Qwen2.5-Coder-3B and XiYanSQL 3B.
GCD was not globally beneficial: it helped or tied the fine-tunes but hurt
several bases and imposed substantial latency on weak models. The matrix
therefore chose GCD independently for every artifact.

On gold_v2, identical fine-tuning improved Qwen from 22.00% to 52.50% EX and
XiYan from 28.50% to 65.50%. The selected XiYan fine-tune beat the Qwen
fine-tune by 13.0 points with a paired 95% interval of [+6.5, +19.5], so no
tie-break was needed.

Five-seed temperature studies tested 0.0, 0.1, 0.3, and 0.7 for both bases
and both fine-tunes. No nonzero temperature delivered both a two-point mean
EX improvement and a paired interval excluding zero. All four normal
generation configurations therefore remain deterministic.

Self-consistency is a separate role-specific calibration. Two
temperature-0.7 samples around the deterministic anchor improved aggregate
EX to 66.80% and valid SQL to 95.40% across 1,000 item-trials, with 40 No
Consensus outcomes and roughly 2.17× the single-shot p95 latency.

## Runtime correctness

Positional generation calls were replaced by `SQLGenerationRequest`.
Candidate roles are explicit for initial, repair, deterministic anchor, and
consistency sample. Production settings come from the verified manifest;
nonzero candidates use fresh cryptographically random UInt64 seeds passed to
MLX and persisted.

Voting groups executed results by stable SHA-256 identity. It requires a
strict majority and has explicit Consensus, No Consensus, and degraded
anchor-failure/truncation outcomes. It never relies on Swift `Hasher`,
dictionary iteration, or a plurality. No Consensus shows the executed
complete anchor and a user-facing notice.

Python and Swift share golden canonical-result fixtures. Numeric SQLite
storage classes normalize with four-decimal half-even rounding; TEXT,
complete BLOB bytes, and NULL remain distinct; duplicates and arity matter;
row order and labels do not. Row-cap truncation is explicit and cannot be
mistaken for a complete match.

Grounding now resolves literals to columns conservatively, supports only
`=` and `IN`, checks only declared entity/categorical domains, and records
typed skips for dates, free-form fields, LIKE, ranges, expressions, and
unresolved bindings. Successful complete domains cache per column; failed or
partial loads do not. A catalog degradation preserves the valid answer,
records exact table/column/error telemetry, suppresses an unsupported notice,
and retries later. Empty edit-distance inputs are handled explicitly.

## Telemetry and persistence

The mutable “latest value wins” fields were replaced by immutable
`TurnTelemetry`. It contains original and standalone questions, rewrite/gate
decisions, stage and total integer-microsecond timings, every candidate
request/result, complete typed rows, repair chain, grounding activity, vote
trigger/outcome, selected candidate, and selection reason.

Candidate IDs survive generation and execution, so repairs and vote samples
cannot overwrite baseline data. Developer mode, chat history, and JSONL
render the same record. Schema-versioned custom decoding preserves old
history. App and evaluation row caps are 500 and 10,000 respectively, with
explicit truncation. Exports are documented as portfolio data.

## Build and parity

The broken static `models/SQLModel` reference is gone. Xcode invokes the
manifest fetcher through the frozen `uv` environment. Debug is cache-only at
build time and falls back to first-use pinned download. Release must download
or reuse, verify, and bundle the exact selected snapshot.

The clean Release build independently downloaded the public winner and the
bundle inspector matched the source and embedded manifest SHA-256, all 12
files, the 1,747,812,702-byte model tree, both licenses, and the notice. MLX
Swift is pinned exactly to 0.31.4 and mlx-swift-lm to 3.31.4.

Full parity ran all 200 gold_v2 items. Python scored 65.50% EX / 93.00%
valid SQL; Swift scored 65.00% / 92.00%. Every one of 14 differences is
explained. One identical malformed query exposed a real SQLite 3.53.3 versus
3.43.2 behavior difference, which remains a documented compatibility
limitation.

## Remaining limitations

Completion here does not turn CREG into a general or production financial
system. It remains limited to one frozen synthetic schema and read-only use.
Physical-device memory, thermal, energy, and end-to-end latency still require
validation on target iPhones. The training corpus needs broader linguistic
diversity to reduce template-family overfitting. SQL generation should be
hardened against engine-version-sensitive correlated aliases. Any model,
prompt, grammar, tokenizer, dependency, schema, database, or gold-set change
requires new immutable evidence and full parity.

Telemetry exports include questions, generated SQL, errors, seeds, and full
rows up to the cap. They must be handled as portfolio data.

## Historical PR #1 result

PR #1's prior winner and scores are intentionally not repeated as verified
results. They remain available only in the prominently labeled
`incomplete-provenance` legacy archive for historical diagnosis.
