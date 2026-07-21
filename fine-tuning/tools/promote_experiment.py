"""Promote an existing screening run without repeating seed-424242 training."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eval.run_artifacts import write_json
from eval.wandb_evidence import synchronize_manifest
from tools.fetch_model import load_manifest, verify_artifact_tree_at_use
from tools.run_experiment import (
    MODEL_MANIFEST,
    MODELS_DIR,
    _fuse_selected_checkpoint,
    finalize_synchronized_manifest,
    local_artifact_path,
)


def base_artifact_for(model_manifest: dict, model_key: str) -> dict:
    artifact = next(
        (item for item in model_manifest["models"] if item["key"] == model_key),
        None,
    )
    if artifact is None:
        raise SystemExit(f"training run references missing base model key: {model_key}")
    return artifact


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--training-run", type=Path, required=True)
    parser.add_argument("--stage", choices=["promoted", "final"], required=True)
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    parser.add_argument("--model-manifest", type=Path, default=MODEL_MANIFEST)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest_path = args.training_run.resolve() / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") not in {
        "complete",
        "local_complete",
        "awaiting_wandb",
        "wandb_complete",
    }:
        raise SystemExit("experiment is not in a resumable promotion state")
    current = manifest["experiment"]["stage"]
    if current == "final" and manifest.get("status") == "complete":
        raise SystemExit(f"run is already {current}")
    if current not in {"screening", "promoted"} and current != args.stage:
        raise SystemExit(f"unsupported promotion from {current}")

    if current != args.stage:
        manifest["experiment"]["stage"] = args.stage
        wandb_stage = "confirmation" if args.stage == "promoted" else args.stage
        manifest["wandb"]["job_type"] = wandb_stage
        manifest["wandb"]["tags"] = [
            tag for tag in manifest["wandb"]["tags"] if not tag.startswith("stage:")
        ] + [f"stage:{wandb_stage}"]
    if not manifest["outputs"].get("fused"):
        manifest["outputs"]["fused"] = str(
            args.models_dir.resolve()
            / "fused"
            / (
                f"{manifest['run_id']}-iter-"
                f"{manifest['checkpoint_evaluation']['selected']['iteration']:06d}"
            )
        )
    manifest["status"] = "local_complete"
    write_json(manifest_path, manifest)

    # Re-sync first so promoted runs publish every checkpoint and the new
    # stage receipt can authorize fusion.
    synchronize_manifest(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    if not manifest.get("fused_reference"):
        model_manifest = load_manifest(args.model_manifest.resolve())
        artifact = base_artifact_for(
            model_manifest,
            manifest["experiment"]["model_key"],
        )
        base = local_artifact_path(artifact, args.models_dir.resolve())
        verify_artifact_tree_at_use(base, artifact)
        _fuse_selected_checkpoint(manifest_path, artifact, base)
    synchronize_manifest(manifest_path)
    result = finalize_synchronized_manifest(manifest_path)
    print(
        json.dumps(
            {
                "run_id": result["run_id"],
                "stage": result["experiment"]["stage"],
                "status": result["status"],
                "selected_iteration": result["checkpoint_evaluation"]["selected"][
                    "iteration"
                ],
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
