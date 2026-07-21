# Fine-Tuning Strategy: LoRA Before Dense Fine-Tuning

**Status:** Recommendation
**Date:** 2026-07-20

## Decision

CREG should use LoRA as its primary fine-tuning method and treat dense
fine-tuning as a measured escalation, not as the default.

Dense fine-tuning belongs in the evaluation matrix because it may improve
execution accuracy after a strong LoRA configuration has plateaued. We should
not invest in it before the gold set, synthetic-data pipeline, and failure
taxonomy can tell us whether additional trainable capacity is actually the
limiting factor.

In short: **consider dense fine-tuning, but do not replace the LoRA-first
plan with it.**

## Why LoRA Is the Better Starting Point

### The required adaptation is narrow

CREG is not teaching a general-purpose model an entirely new capability. It is
specializing an existing code-capable model for:

- one frozen SQLite schema;
- one domain vocabulary;
- a bounded collection of join, filter, aggregation, and window-query
  patterns; and
- one constrained output format.

That is plausibly a low-rank change to the base model's behavior, which is the
case LoRA is designed to handle.

### Our training data will initially be scarce and mostly synthetic

The [PRD](../CREG%20%E2%80%94%20Product%20Requirements%20Document.md)
reserves only 150–300 hand-verified examples for the gold set. Those examples
must remain held out, so the initial training corpus will be generated through
templating, pattern transfer, and paraphrasing.

Dense fine-tuning gives the model much more capacity to memorize generator
artifacts, repeated SQL shapes, and superficial phrasing. LoRA's restricted
update is useful regularization until the dataset is large, varied, and
demonstrably clean.

### LoRA makes the failure-driven loop faster

The intended workflow is iterative:

1. Train.
2. Evaluate execution accuracy.
3. Classify failures.
4. Add targeted examples.
5. Repeat.

Small adapters make these iterations faster and cheaper. They also let us keep
multiple experiments without storing a separate multi-gigabyte checkpoint for
each one.

### Dense tuning does not improve the shipping footprint

Both approaches ultimately produce the same kind of deployment artifact:

1. apply or fuse the learned weights;
2. quantize the resulting model to 4-bit; and
3. bundle it for MLX inference.

Dense fine-tuning therefore has no inherent on-device latency, memory, or app
size advantage. It is worth adopting only if it produces a meaningful,
repeatable improvement in execution accuracy.

## Why Dense Fine-Tuning Still Deserves an Experiment

LoRA is an assumption that the useful weight update can be represented at low
rank. That assumption may fail when the task requires coordinated changes
across many layers or when a small model is near its capacity limit.

CREG also has two characteristics that make a later dense experiment
reasonable:

- The model is a dedicated SQL specialist, so preserving every general-purpose
  behavior is less important than it would be for a user-facing assistant.
- Training is a developer-side, one-time cost. If dense tuning produces a
  substantial accuracy gain that survives quantization, additional training
  time is acceptable.

The correct conclusion is not that LoRA always matches dense tuning. It is that
we need a strong LoRA baseline before the comparison says anything useful.

## Scale and Resource Implications

The current default candidate,
`Qwen2.5-Coder-3B-Instruct`, has approximately 3.09 billion parameters,
including 2.77 billion non-embedding parameters across 36 transformer layers.

With MLX-LM's current default LoRA configuration—rank 8 over the last 16
layers—the approximate trainable parameter counts are:

| Configuration | Approximate trainable parameters |
| --- | ---: |
| LoRA, rank 8, last 16 layers | 6.7M |
| Dense update, last 16 layers | 1.23B |
| Dense update, all 36 transformer layers | 2.77B |

Thus, a last-16-layer dense run updates roughly 185 times as many parameters as
the default LoRA run. Updating all transformer layers increases that to more
than 400 times the default LoRA parameter count.

On this project's 48 GB development Mac, a dense experiment on the 3B model is
plausible with a small batch, gradient accumulation, gradient checkpointing,
and controlled sequence lengths. It is not lightweight:

| Training setup | Rough persistent-memory floor before activations |
| --- | ---: |
| BF16 LoRA | About 6–7 GB plus adapter optimizer state |
| Dense last 16 layers with Adam | About 14 GB |
| Dense all 36 layers with Adam | About 23 GB |

These are planning estimates, not benchmarks. Activations, Metal allocator
behavior, sequence length, and checkpointing can materially increase peak
memory.

## Recommended Experiment Ladder

### 0. Establish the untuned baseline

Evaluate the base model using the exact production prompt, schema
serialization, and grammar settings. Run grammar-constrained decoding both on
and off as required by the PRD.

### 1. Build a strong regular-LoRA baseline

For a 3B model on a 48 GB Mac, prefer LoRA on the unquantized BF16 base over
QLoRA for the main accuracy experiments. Quantize only after fusion. This
avoids conflating adapter capacity with quantization effects while remaining
well within the available training memory.

Sweep at least:

- rank: 8, 16, and 32;
- adapted layers: last 16 and all 36;
- prompt-token loss masking: on and off; and
- learning rate and training duration.

The default rank-8, last-16-layer configuration is only a starting point. It
must not be treated as the best LoRA can do.

### 2. Test higher-capacity parameter-efficient tuning

If LoRA performance is still improving with rank:

- try rank 64;
- evaluate DoRA; and
- inspect whether particular failure categories benefit from adapting all
  layers.

### 3. Test partial dense tuning

MLX-LM's `full` mode densely updates the selected transformer layers. Use that
to compare the strongest LoRA run with dense updates of the last 4, 8, and 16
layers.

Partial dense tuning is the natural bridge between LoRA and an all-layer run.
If it does not beat strong LoRA, there is little reason to pay for all-layer
dense tuning.

### 4. Test all-layer dense tuning

Run this only if partial dense tuning shows a clear upward trend or the failure
analysis indicates that LoRA capacity is the bottleneck.

Use a lower learning-rate range than the LoRA sweep and require early stopping.
An all-layer run should not reuse LoRA hyperparameters blindly.

## Requirements for a Fair Comparison

Every configuration should use:

- the same versioned training-data snapshot;
- the same prompt and schema serialization;
- the same train/validation split;
- the untouched hand-verified gold set for final scoring;
- method-appropriate learning-rate tuning;
- at least three random seeds for finalists; and
- evaluation of the fused, final 4-bit artifact, not only the training-time
  checkpoint.

Report:

- overall execution accuracy;
- execution accuracy by difficulty tier;
- the existing failure taxonomy;
- training and validation loss;
- peak memory and training time;
- accuracy before and after 4-bit quantization; and
- a small general instruction-following and SQL-validity smoke suite.

Training loss or perplexity alone is not a sufficient reason to choose dense
fine-tuning. CREG's decision metric is execution accuracy.

## Escalation and Adoption Gates

### Start dense experiments only when

- the gold set and evaluator are complete;
- synthetic examples pass the planned quality gate;
- the strongest LoRA/DoRA configurations have plateaued;
- LoRA remains meaningfully below the product's target accuracy; and
- the remaining errors are semantic model errors rather than data defects,
  value-grounding failures, prompt problems, or over-constrained decoding.

### Adopt dense fine-tuning only when

- it improves held-out execution accuracy by roughly 2–3 absolute percentage
  points or more;
- the improvement repeats across seeds;
- it improves or preserves the difficult join, nested-query, and window-query
  tiers;
- it does not introduce a material regression in simpler queries;
- the gain survives fusion and 4-bit quantization; and
- the additional training complexity remains reproducible and maintainable.

The 2–3 point threshold is a decision heuristic, not a statistical rule. The
final comparison should include paired confidence intervals because a
150–300-example gold set has relatively coarse accuracy increments.

## Immediate Recommendation

Do not change the current implementation plan to dense fine-tuning. The
project is still building the evaluation harness, while synthetic-data
generation is scheduled for a later milestone.

When the training milestone begins:

1. add `lora`, `dora`, partial-dense, and all-layer-dense as explicit harness
   axes;
2. make BF16 LoRA across all transformer layers the serious baseline;
3. complete the LoRA and DoRA sweeps first; and
4. run dense configurations only after the escalation gate is met.

This preserves the option to use dense fine-tuning without allowing an
expensive training method to distract from the higher-leverage work: data
quality, failure analysis, schema grounding, and evaluation rigor.

## References

- [MLX-LM fine-tuning documentation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md)
- [Qwen2.5-Coder-3B-Instruct model card](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct)
- [LoRA: Low-Rank Adaptation of Large Language Models](https://arxiv.org/abs/2106.09685)
- [QLoRA: Efficient Finetuning of Quantized LLMs](https://arxiv.org/abs/2305.14314)
- [LoRA vs. Full Fine-Tuning: A Theoretical Perspective](https://arxiv.org/abs/2605.19018)
