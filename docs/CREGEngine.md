# ``CREGEngine``

Build and evaluate an on-device natural-language-to-SQL pipeline for a fixed
commercial real-estate schema.

## Overview

CREGEngine orchestrates the local query pipeline: deterministic starters,
generation attempts, validation and bounded repair, execution, grounding, result
selection, follow-up preparation, and operation reporting.

The surrounding library targets provide the rest of the runtime. CREGCore owns
shared clients, models, events, diagnostics, and result identity; CREGData owns
the read-only database boundary and grounding heuristics; CREGInference owns the
MLX model adapter and prompt resources; CREGFeatures owns application state,
persistence, telemetry, and presentation; and CREGApplication composes the live
dependencies and root view. This site publishes API documentation for all six
library targets.

The articles below document the architecture, experimental evidence, release
verification, and decisions that define the engine's behavior.

## Topics

### Start Here

- <doc:walkthrough>
- <doc:final-report>

### Architecture and Behavior

- <doc:grounding-corrections>
- <doc:data-synthesis>
- <doc:model-selection>
- <doc:fine-tuning-strategy>

### Evaluation and Release Evidence

- <doc:eval>
- <doc:training-report>
- <doc:self-consistency-report>
- <doc:parity-report>
- <doc:verification-report>
- <doc:license-report>
- <doc:leaderboard>
- <doc:gold-review-v1>
- <doc:gold-review-v2>

### Architecture Decisions

- <doc:0001-schema-semantics>
- <doc:0002-mlx-over-coreml>
- <doc:0003-hybrid-eval-harness>
- <doc:0004-manifest-pinned-model-and-build-artifacts>
- <doc:0005-deterministic-anchor-voting-and-result-identity>
