# ``CREGEngine``

Build and evaluate an on-device natural-language-to-SQL pipeline for a fixed
commercial real-estate schema.

## Overview

CREGEngine contains the local query pipeline, model adapters, read-only database
boundary, grounding checks, deterministic result identity, voting, diagnostics,
and telemetry shared by the CREG app and its Swift evaluation harness.

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
