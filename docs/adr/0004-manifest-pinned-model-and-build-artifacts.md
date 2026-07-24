# Manifest-pinned model and build artifacts

Status: accepted.

## Context

A repository name such as `owner/model` is mutable, and a local
`models/SQLModel` directory says nothing about which Hub snapshot, conversion
options, or license produced a shipped bundle. PR #1 also demonstrated that
model outputs cannot be reproduced after the original fine-tuned directory
and training configuration disappear.

CREG needs one identity to connect acquisition, evaluation, publication,
Xcode builds, and runtime telemetry. Model weights are too large for Git, so
that identity must remain verifiable after local caches are removed.

## Decision

`model-manifest.json` is the only model inventory and production-selection
source. Every source or public derived artifact declares:

- a repository and full 40-character immutable revision;
- source format, local materialization path, quantization, and license;
- the complete expected file inventory with size and SHA-256;
- a deterministic directory SHA-256 over that inventory; and
- conversion and training provenance where applicable.

An unpublished local fine-tune is temporarily identified by its complete
directory SHA-256 and immutable training run. It cannot become production.
After publication, it is replaced by the public Hub commit and the complete
fresh-downloaded inventory.

The manifest fetcher implements `--all`, `--model`, and `--production`.
Floating revisions are rejected. XiYanSQL conversion has every MLX option
declared, and both source and converted trees are verified. Weights live in
the ignored `models/` materialization and Hugging Face cache.

License inheritance is conservative and content-addressed. The pinned
XiYanSQL `config.json` identifies `Qwen2.5-Coder-3B-Instruct` as its origin,
so the Apache license published by XiYan is not treated as erasing the Qwen
Research License. XiYan and its derivative are marked non-commercial and
distribute both `LICENSE` (XiYan Apache-2.0) and `QWEN_LICENSE` (the pinned
Qwen Research License). Direct Qwen2.5-Coder-3B derivatives distribute the
same pinned Qwen license. Both lineages also distribute the hash-pinned
`NOTICE` containing the required Qwen attribution, Built/Improved using Qwen
statement, non-commercial warning, and CREG modification notice.

The Xcode project has no static `models/SQLModel` reference. Its always-run
build phase uses the frozen `uv` environment for every configuration. Release
downloads or reuses only the manifest-selected production snapshot, verifies
every byte, and bundles it as `SQLModel` with a manifest-bound receipt. Debug
may instead select a locally complete reliability-v3 checkpoint, verify its
finite training, multi-snapshot evaluation, adapter hash, and pinned base,
then fuse it into a locally receipt-bound experimental bundle. This Debug-only
path does not require a W&B receipt and is visibly labeled in the app; Release
rejects its `debug-candidate` manifest. Runtime Hub fallback remains unsupported.

## Consequences

A production model upgrade is a manifest and evidence change, never an
unreviewed cache change. Debug experiments are traceable to an immutable local
run and checkpoint hash but are not production claims. Builds need enough disk
space for fusion plus the bundle copy. A fine-tune cannot ship in Release until
publication and fresh-download verification succeed.
