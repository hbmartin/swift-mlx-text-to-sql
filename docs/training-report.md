# Reproducible finalist training report

This report records the replacement QLoRA training used after PR #1. The
original merged fine-tuned weights, seed, and complete mlx-lm configuration
were unavailable, so the historical run could not be reproduced. The two runs
below start from pinned, verified model trees and share one complete training
configuration and one byte-reproduced corpus.

The authoritative machine-readable records are:

- `eval/training-runs/qlora-qwen25-coder-3b-seed-424242/manifest.json`
- `eval/training-runs/qlora-xiyansql-qwencoder-3b-seed-424242/manifest.json`

## How the finalists were chosen

All four pinned bases were screened on all 60 gold_v1 items at temperature
0.0 with GCD both on and off. Each family contributed its better GCD result;
families were then ordered by execution accuracy, valid SQL, worst-tier
execution accuracy, p95 latency, and bundle size.

| Rank | Base family | Best GCD | EX | Valid SQL | Worst-tier EX | p95 |
|---:|---|:---:|---:|---:|---:|---:|
| 1 | Qwen2.5-Coder-3B | on | 35.00% | 85.00% | 16.67% | 14.803 s |
| 2 | XiYanSQL-QwenCoder-3B | off | 31.67% | 88.33% | 0.00% | 2.344 s |
| 3 | Qwen2.5-Coder-1.5B | off | 23.33% | 70.00% | 0.00% | 1.367 s |
| 4 | Qwen3-1.7B | off | 20.00% | 73.33% | 0.00% | 1.752 s |

This selected the Qwen2.5-Coder-3B and XiYanSQL-QwenCoder-3B base families.
The full analysis, including every input manifest hash, is
`eval/analyses/screen-c73e14c5f7b91c79/analysis.json`.

## Frozen inputs

| Input | Identity |
|---|---|
| Qwen base | `mlx-community/Qwen2.5-Coder-3B-Instruct-4bit@3dd939c621c08e5753d5b89f35a2642cd83b98ca` |
| Qwen base tree SHA-256 | `bb07390155226383c705229516cb9e333fcbf58e38d490a768bac78da530cd4b` |
| XiYan source | `XGenerationLab/XiYanSQL-QwenCoder-3B-2502@0d35ce19d4e4d78d82d19b18b3e0f1c7a86eb535` |
| XiYan converted tree SHA-256 | `a527bbfcb01aeb07017483f3204f6c32df1654dfd70f019b1f624ede002afe23` |
| Training configuration SHA-256 | `63a139bb79e5ad77d0241b9b76d0c2892a3459019bcfad04367d8d932800b545` |
| Corpus manifest SHA-256 | `4e3d25923a8426ba3c09349d240a1c77aca79daf5c69631694d28dfe4374cabe` |
| Python lock SHA-256 | `034b816d176c52f6a0ba5eb5f657f1dc1a7fbd222edd564e32e75361adb91cd3` |
| Training runner SHA-256 | `b2765239ade40bd3231f057de1aec431ac227e7a8ce9769fc4651df29303943c` |
| Corpus generator SHA-256 | `416f1370045de5fffe69a557fa1486fd80f4de645a7f4311b9ae878e3ccd79c9` |
| Held-out gold_v2 SHA-256 | `2bde4dedc23bc7938d0250f2e2d5e22502903c8caad6c0951e1bbca9d0d77036` |

Both run manifests record source commit
`a35f6c06ad031e91512ba3977c3430d241b59493` and a dirty working tree. Because
the runs were intentionally executed while the follow-up implementation was
uncommitted, reproducibility rests on the recorded per-input hashes rather
than the commit alone. The training runner, generator, configuration, corpus,
model artifact lock, and dependency lock are all content-addressed in each
run.

## Corpus regeneration and holdout

Before each training command, the runner regenerated the corpus into that
run's own directory and required byte-for-byte equality with the committed
files:

| File | SHA-256 | Regeneration |
|---|---|---|
| `fine-tuning/synth/out/train.jsonl` | `3a9ad4806692cdc89e8e68c77e29c5e1eedaefac5745c3a87bd4e4fb1758021e` | Equal |
| `fine-tuning/synth/out/valid.jsonl` | `b0e72fde78f50e80bc5bdd4664eb7e87695db8a52e042067cfb32ddfc0fcec33` | Equal |
| `fine-tuning/synth/out/gate_stats.json` | `d63b2ae38ec22276dc7706c34d9f12b5f301909e50f01c3c7412043abd22f442` | Equal |

The generator produced 1,441 raw examples. The gate rejected three exact
gold-set collisions and 14 degenerate examples; it found zero execution
errors, grammar failures, or within-batch duplicates. The retained corpus has
1,424 examples across 65 query families and tiers 1/2/3 in counts
357/1,003/64. Its deterministic split is 1,353 training and 71 validation
examples. No gold_v2 item is a training or validation input.

## Complete training configuration

Both bases used the exact committed `fine-tuning/config/qlora.yaml`:

```yaml
model: REQUIRED_FINALIST_MODEL_OVERRIDE
train: true
fine_tune_type: lora
optimizer: adam
optimizer_config:
  adam: {}
  adamw: {}
  muon: {}
  sgd: {}
  adafactor: {}
data: synth/out
seed: 424242
num_layers: 16
batch_size: 4
iters: 600
val_batches: 25
learning_rate: 0.0001
steps_per_report: 10
steps_per_eval: 200
grad_accumulation_steps: 1
resume_adapter_file: null
adapter_path: REQUIRED_IMMUTABLE_ADAPTER_PATH_OVERRIDE
save_every: 100
test: false
test_batches: 500
max_seq_length: 2048
config: null
grad_checkpoint: false
clear_cache_threshold: 0
lr_schedule: null
lora_parameters:
  rank: 8
  dropout: 0.0
  scale: 20.0
mask_prompt: true
report_to: null
project_name: creg-sql
```

The runner replaces only the fail-closed `model`, `data`, and `adapter_path`
sentinels with each immutable run's absolute paths. There are no floating
mlx-lm defaults in the recorded training recipe.

## Training observations

| Family | Started (UTC) | Completed (UTC) | Duration | Tokens | Peak memory |
|---|---|---|---:|---:|---:|
| Qwen2.5-Coder-3B | 2026-07-20 18:38:58 | 2026-07-20 19:44:16 | 1:05:18 | 107,177 | 17.157 GB |
| XiYanSQL-QwenCoder-3B | 2026-07-20 19:44:22 | 2026-07-20 20:53:10 | 1:08:48 | 107,177 | 17.158 GB |

Validation and contemporaneous training losses:

| Family | Initial val | Iter 200 val / train | Iter 400 val / train | Iter 600 val / train |
|---|---:|---:|---:|---:|
| Qwen2.5-Coder-3B | 0.917 | 0.011 / 0.016 | **0.007** / 0.009 | 0.018 / 0.002 |
| XiYanSQL-QwenCoder-3B | 0.810 | 0.014 / 0.017 | **0.005** / 0.001 | 0.008 / 0.007 |

Both runs minimized recorded validation loss at iteration 400 and regressed
at iteration 600, particularly the Qwen run. This is a visible overfitting
signal, not evidence that a particular adapter checkpoint is better on the
held-out task. The approved experiment specified one identical 600-iteration
job per family, so the fused finalists use the final checkpoint. Model
selection depends on the separately held-out gold_v2 execution matrix, not
training or validation loss.

## Fused artifact evidence

| Finalist | Final adapter SHA-256 | Adapter-tree SHA-256 | Training-log SHA-256 | Fused tree SHA-256 |
|---|---|---|---|---|
| `ft-qwen25-coder-3b` | `fbcbd706dc628db1a8c4fd7137f7ec944573a16c13ccf47216952434f223f719` | `b31b6b1997091f796d83109bf3bba91856a7c301eedf3c78541d949fcd3ae349` | `bd81f135e0699d846a4a08ca1552c74c48a6fefca6b419e1d727a3d90e59ae32` | `5cbda9c9115f01df2a8a3a23a0de0a07447de6f3a5053f8c05a89c6bf33a3aa6` |
| `ft-xiyansql-qwencoder-3b` | `c2049b552ffc87a4aa35030c2568b4b3e3ae556f9e9569cd3df3e53e86551f8c` | `8726d3bd0594661dd077907b6d463da028f9856e591e717eeca1564bbe8e2efb` | `ac63718348727ecd2ad62fdba27b5c9475f17e823f1e4c4991873511074f8fe5` | `af4ec6faa63ef2dbae8731004f61e9d621c256ca826a7aa84451eabe239a0840` |

Fusion preserved MLX affine 4-bit quantization with group size 64 for both
artifacts. After writing each complete file inventory and directory digest,
the runner loaded the fused directory through `mlx_lm.load`; both clean-load
checks passed. Local registration then reverified every required file before
allowing evaluation.

## Public finalist snapshots

Both fused finalists were published to public Hugging Face repositories. The
publisher uploaded a staging copy, resolved the returned commit, forced a
fresh download into a new directory, verified every file's size and SHA-256,
and only then replaced the local evaluation materialization with the exact
public bytes. The versioned model manifest was subsequently updated and both
entries passed `fetch_model.py --verify-only`.

| Finalist | Immutable public snapshot | Fresh tree SHA-256 | Publication record SHA-256 |
|---|---|---|---|
| `ft-qwen25-coder-3b` | [`hbmartin/creg-sql-mlx-community-qwen2-5-coder-3b-instruct-4bit-mlx-4bit@430d383`](https://huggingface.co/hbmartin/creg-sql-mlx-community-qwen2-5-coder-3b-instruct-4bit-mlx-4bit/tree/430d38301eedb6c61e48c25c7d38a2b227bf56c6) | `c09f7ec567a5d45dbbb3fbbd35b1e9db6933b6db5bf0e6ab1fd772af275c5204` | `2a983c6251af85755facc3f5ee2af6b760c405e818570f9a3b2403307703b369` |
| `ft-xiyansql-qwencoder-3b` | [`hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit@7f97a54`](https://huggingface.co/hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit/tree/7f97a54819b9329338a5353266d6d2a1294eb341) | `a3befce92b39afe29c0c0b01c534bd81731f151940470697d5f2038c89efd8c6` | `420bcfe1788704e053e0dc979076192e7dc1c1face016da8a56a51303600b2d2` |

The Qwen snapshot has ten declared files; the XiYan snapshot has twelve,
including both `LICENSE` and `QWEN_LICENSE`. The public tree digests differ
from the pre-publication fused digests because publication deliberately adds
the model card, license material, notice, and Hub attributes. The weight-file
hashes remain independently declared in `model-manifest.json`.

## Interpretation limits

These runs prove that the prescribed inputs can be regenerated, two adapters
can be trained under the same recipe, and the fused 4-bit artifacts can be
identified and loaded. Training evidence alone does not establish production
suitability. The independent evidence is now complete: `docs/eval.md`
records held-out execution and temperature selection,
`docs/self-consistency-report.md` records voting calibration,
`docs/parity-report.md` records full Swift parity, and
`docs/verification-report.md` records clean-cache Release inspection.
