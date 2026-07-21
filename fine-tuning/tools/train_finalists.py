"""Reproduce the corpus, train exactly two selected bases, and fuse 4-bit models.

This command intentionally requires two explicit manifest keys. It never
selects finalists itself and never overwrites adapters, fused models, or
training-run directories.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from eval.run_artifacts import (
    REPO_ROOT,
    create_run_directory,
    git_provenance,
    hardware_provenance,
    input_hash,
    sha256_file,
    write_json,
)
from tools.fetch_model import (
    LOCK_FILE,
    directory_digest,
    directory_inventory,
    load_manifest,
    verify_artifact_tree_at_use,
)

# `artifact_path` lives in the evaluator to avoid a circular tool import.
def local_artifact_path(artifact: dict[str, Any], models_dir: Path) -> Path:
    conversion = artifact.get("conversion")
    directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    return models_dir / directory


MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
CORPUS_MANIFEST = REPO_ROOT / "fine-tuning" / "config" / "corpus-manifest.json"
TRAINING_CONFIG = REPO_ROOT / "fine-tuning" / "config" / "qlora.yaml"
TRAINING_RUNS = REPO_ROOT / "eval" / "training-runs"
MODELS_DIR = REPO_ROOT / "models"
CORPUS_GENERATOR = REPO_ROOT / "fine-tuning" / "synth" / "generate_training.py"
UV_LOCK = REPO_ROOT / "fine-tuning" / "uv.lock"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-key", action="append", required=True, help="selected base key"
    )
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    parser.add_argument("--training-runs-dir", type=Path, default=TRAINING_RUNS)
    return parser.parse_args()


def verify_regenerated_corpus(run_directory: Path) -> dict[str, Any]:
    generated = run_directory / "regenerated-corpus"
    subprocess.run(
        [
            sys.executable,
            "-m",
            "synth.generate_training",
            "--out-dir",
            str(generated),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    declaration = json.loads(CORPUS_MANIFEST.read_text())
    comparisons = []
    for file in declaration["files"]:
        committed = REPO_ROOT / file["path"]
        regenerated = generated / committed.name
        committed_hash = sha256_file(committed)
        regenerated_hash = sha256_file(regenerated)
        if (
            committed_hash != file["sha256"]
            or regenerated_hash != file["sha256"]
            or committed.read_bytes() != regenerated.read_bytes()
        ):
            raise RuntimeError(
                f"regenerated corpus differs byte-for-byte: {committed}"
            )
        comparisons.append(
            {
                "committed": input_hash(committed),
                "regenerated": input_hash(regenerated),
                "byte_for_byte_equal": True,
            }
        )
    return {
        "manifest": input_hash(CORPUS_MANIFEST),
        "files": comparisons,
        "gold_v2_held_out": input_hash(
            REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
        ),
    }


def train(
    artifact: dict[str, Any],
    models_dir: Path,
    runs_dir: Path,
) -> None:
    base = local_artifact_path(artifact, models_dir)
    if not (base / LOCK_FILE).is_file():
        raise RuntimeError(
            f"{artifact['key']}: verified base is missing; fetch it first"
        )
    # Re-hash the base tree now: the recorded base digest must describe the
    # weights this training run actually reads, not what the lock file
    # claimed at fetch time.
    verified_base_sha256 = verify_artifact_tree_at_use(base, artifact)
    run_id = f"qlora-{artifact['key']}-seed-424242"
    run_directory = create_run_directory(runs_dir, run_id)
    adapter = models_dir / "adapters" / run_id
    fused = models_dir / f"creg-sql-{artifact['key']}-mlx-4bit"
    if adapter.exists() or fused.exists():
        raise RuntimeError(
            f"refusing to overwrite adapter/fused output for {artifact['key']}"
        )

    corpus = verify_regenerated_corpus(run_directory)
    command = [
        sys.executable,
        "-m",
        "mlx_lm",
        "lora",
        "--config",
        str(TRAINING_CONFIG),
        "--model",
        str(base),
        "--data",
        str(run_directory / "regenerated-corpus"),
        "--adapter-path",
        str(adapter),
    ]
    manifest = {
        "schema_version": 1,
        "run_id": run_id,
        "status": "running",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "command": command,
        "git": git_provenance(),
        "hardware": hardware_provenance(),
        "base": {
            "key": artifact["key"],
            "repository": artifact["repository"],
            "revision": artifact["revision"],
            "lock": input_hash(base / LOCK_FILE),
        },
        "configuration": input_hash(TRAINING_CONFIG),
        "corpus": corpus,
        "inputs": {
            "training_runner": input_hash(Path(__file__)),
            "corpus_generator": input_hash(CORPUS_GENERATOR),
            "model_manifest": input_hash(MODEL_MANIFEST),
            "uv_lock": input_hash(UV_LOCK),
        },
        "outputs": {
            "adapter": str(adapter),
            "fused": str(fused),
        },
    }
    write_json(run_directory / "manifest.json", manifest)
    log_path = run_directory / "training.log"
    with log_path.open("xb") as log:
        process = subprocess.run(
            command,
            cwd=REPO_ROOT / "fine-tuning",
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    if process.returncode != 0:
        manifest["status"] = "failed"
        manifest["training_log"] = input_hash(log_path)
        write_json(run_directory / "manifest.json", manifest)
        raise RuntimeError(
            f"training failed for {artifact['key']}; see {log_path}"
        )

    fuse_command = [
        sys.executable,
        "-m",
        "mlx_lm",
        "fuse",
        "--model",
        str(base),
        "--adapter-path",
        str(adapter),
        "--save-path",
        str(fused),
    ]
    subprocess.run(
        fuse_command, cwd=REPO_ROOT / "fine-tuning", check=True
    )
    # Loading through mlx_lm is the minimum artifact validation before eval.
    subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "from mlx_lm import load; "
                f"load({str(fused)!r}); "
                "print('fused model load verified')"
            ),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )

    inventory = directory_inventory(fused)
    training_provenance = {
        "run_id": run_id,
        "seed": 424242,
        "base_repository": artifact["repository"],
        "base_revision": artifact["revision"],
        "base_directory_sha256": verified_base_sha256,
        "configuration": input_hash(TRAINING_CONFIG),
        "corpus_manifest": input_hash(CORPUS_MANIFEST),
        "code_commit": manifest["git"]["commit"],
        "code_dirty": manifest["git"]["dirty"],
        "code_inputs": manifest["inputs"],
        "adapter_files": directory_inventory(adapter),
        "training_log_sha256": sha256_file(log_path),
    }
    lock = {
        "schema_version": 1,
        "key": f"ft-{artifact['key']}",
        "repository": None,
        "revision": None,
        "format": "mlx",
        "quantization": {
            "bits": 4,
            "group_size": 64,
            "mode": "affine",
        },
        "all_files": inventory,
        "verified_files": inventory,
        "directory_sha256": directory_digest(inventory),
        "training_provenance": training_provenance,
    }
    write_json(fused / LOCK_FILE, lock)
    manifest["status"] = "complete"
    manifest["completed_at"] = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
    )
    manifest["training_log"] = input_hash(log_path)
    manifest["fuse_command"] = fuse_command
    manifest["fused_lock"] = input_hash(fused / LOCK_FILE)
    manifest["candidate_manifest_entry"] = {
        "key": lock["key"],
        "display_name": fused.name,
        "repository": None,
        "revision": None,
        "local_directory": fused.name,
        "format": "mlx",
        "derived": True,
        "publication_status": "local-unpublished",
        "training_run": run_id,
        "base_key": artifact["key"],
        "snapshot_directory_sha256": lock["directory_sha256"],
        "quantization": lock["quantization"],
        "license": artifact["license"],
        "required_files": inventory,
        "training_provenance": training_provenance,
    }
    write_json(run_directory / "manifest.json", manifest)


def main() -> None:
    args = parse_args()
    if len(args.model_key) != 2 or len(set(args.model_key)) != 2:
        raise SystemExit("--model-key must be supplied exactly twice with distinct keys")
    manifest = load_manifest(MODEL_MANIFEST)
    artifacts = {model["key"]: model for model in manifest["models"]}
    unknown = set(args.model_key) - set(artifacts)
    if unknown:
        raise SystemExit(f"unknown model keys: {sorted(unknown)}")
    for key in args.model_key:
        if artifacts[key].get("derived"):
            raise SystemExit(f"{key} is already a derived artifact")
    for key in args.model_key:
        train(
            artifacts[key],
            args.models_dir.resolve(),
            args.training_runs_dir.resolve(),
        )


if __name__ == "__main__":
    main()
