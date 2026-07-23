"""Evaluate every saved adapter checkpoint on the development gold set.

This command is intentionally hard-wired to gold_v1, GCD-on, temperature-zero
decoding. It is safe to call from sweep agents because it has no final-test-set
option and therefore cannot make final evidence part of checkpoint selection.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

from eval.experiment import select_development_checkpoint
from eval.run_artifacts import REPO_ROOT, input_hash, sha256_file, write_json


GOLD_DEVELOPMENT = REPO_ROOT / "eval" / "gold" / "gold_v1.jsonl"
DEVELOPMENT_DATABASES = (
    REPO_ROOT / "db" / "creg.sqlite",
    REPO_ROOT / "eval" / "snapshots" / "latest-staggered.sqlite",
    REPO_ROOT / "eval" / "snapshots" / "portfolio-boundaries.sqlite",
)
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
MODELS_DIR = REPO_ROOT / "models"
CHECKPOINT_RE = re.compile(r"^(?P<iteration>[0-9]{7})_adapters\.safetensors$")
Runner = Callable[..., subprocess.CompletedProcess[Any]]


class CheckpointEvaluationError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--training-run", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=MODEL_MANIFEST)
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    return parser.parse_args()


def discover_checkpoints(
    adapter_directory: Path,
    *,
    iterations: int,
    save_every: int = 100,
) -> list[tuple[int, Path]]:
    found: dict[int, Path] = {}
    for path in adapter_directory.glob("*_adapters.safetensors"):
        match = CHECKPOINT_RE.fullmatch(path.name)
        if match:
            found[int(match.group("iteration"))] = path.resolve()
    expected = list(range(save_every, iterations + 1, save_every))
    missing = [iteration for iteration in expected if iteration not in found]
    if missing:
        raise CheckpointEvaluationError(
            f"missing saved checkpoints at iterations {missing}"
        )
    return [(iteration, found[iteration]) for iteration in expected]


def _evaluation_record(
    evaluation_directory: Path,
    *,
    iteration: int,
    checkpoint: Path,
) -> dict[str, Any]:
    manifest_path = evaluation_directory / "manifest.json"
    summary_path = evaluation_directory / "summary.json"
    items_path = evaluation_directory / "items.jsonl"
    for path in (manifest_path, summary_path, items_path):
        if not path.is_file():
            raise CheckpointEvaluationError(
                f"checkpoint {iteration} did not produce {path.name}"
            )
    evaluation_manifest = json.loads(manifest_path.read_text())
    if evaluation_manifest.get("status") != "complete":
        raise CheckpointEvaluationError(
            f"checkpoint {iteration} evaluation is incomplete"
        )
    summary = json.loads(summary_path.read_text())
    if (
        summary.get("gold") != GOLD_DEVELOPMENT.name
        or summary.get("n") != 60
        or summary.get("snapshot_count") != len(DEVELOPMENT_DATABASES)
    ):
        raise CheckpointEvaluationError(
            f"checkpoint {iteration} did not evaluate all 60 gold_v1 items"
        )
    return {
        "iteration": iteration,
        "checkpoint_path": str(checkpoint),
        "checkpoint_sha256": sha256_file(checkpoint),
        "adapter_size_bytes": checkpoint.stat().st_size,
        "manifest_path": str(manifest_path.resolve()),
        "manifest_sha256": sha256_file(manifest_path),
        "summary_path": str(summary_path.resolve()),
        "summary_sha256": sha256_file(summary_path),
        "items_path": str(items_path.resolve()),
        "items_sha256": sha256_file(items_path),
        "summary": summary,
    }


def evaluate_training_checkpoints(
    training_manifest_path: Path,
    *,
    model_manifest: Path = MODEL_MANIFEST,
    models_dir: Path = MODELS_DIR,
    runner: Runner = subprocess.run,
) -> dict[str, Any]:
    training_manifest_path = training_manifest_path.resolve()
    run_directory = training_manifest_path.parent
    training = json.loads(training_manifest_path.read_text())
    experiment = training.get("experiment")
    if not experiment:
        raise CheckpointEvaluationError("training manifest has no experiment config")
    if training.get("checkpoint_evaluation"):
        return training["checkpoint_evaluation"]
    if training.get("status") not in {"training_complete", "evaluating"}:
        raise CheckpointEvaluationError(
            f"training run is not ready for checkpoint evaluation: {training.get('status')}"
        )

    adapter_directory = Path(training["outputs"]["adapter"]).resolve()
    checkpoints = discover_checkpoints(
        adapter_directory,
        iterations=int(experiment["iterations"]),
        save_every=int(experiment["save_every"]),
    )
    comparison_directory = run_directory / "checkpoint-evaluations"
    comparison_directory.mkdir(parents=False, exist_ok=False)
    evaluations_directory = comparison_directory / "runs"
    evaluations_directory.mkdir()
    training["status"] = "evaluating"
    write_json(training_manifest_path, training)

    records: list[dict[str, Any]] = []
    try:
        for iteration, checkpoint in checkpoints:
            evaluation_id = f"checkpoint-{iteration:06d}"
            command = [
                sys.executable,
                "-m",
                "eval.run_eval",
                "--model-key",
                experiment["model_key"],
                "--manifest",
                str(model_manifest.resolve()),
                "--models-dir",
                str(models_dir.resolve()),
                "--adapter-path",
                str(adapter_directory),
                "--adapter-checkpoint",
                str(checkpoint),
                "--gcd",
                "on",
                "--temperature",
                "0",
                "--seed",
                "0",
                "--gold",
                str(GOLD_DEVELOPMENT),
                "--run-id",
                evaluation_id,
                "--runs-dir",
                str(evaluations_directory),
            ]
            for database in DEVELOPMENT_DATABASES:
                command.extend(("--database", str(database)))
            log_path = comparison_directory / f"checkpoint-{iteration:06d}.log"
            with log_path.open("xb") as log:
                completed = runner(
                    command,
                    cwd=REPO_ROOT / "fine-tuning",
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            if completed.returncode:
                raise CheckpointEvaluationError(
                    f"checkpoint {iteration} evaluation failed; see {log_path}"
                )
            records.append(
                _evaluation_record(
                    evaluations_directory / evaluation_id,
                    iteration=iteration,
                    checkpoint=checkpoint,
                )
            )
    except BaseException as error:
        training["status"] = "evaluation_failed"
        training["evaluation_error"] = {
            "type": type(error).__name__,
            "message": str(error),
        }
        write_json(training_manifest_path, training)
        raise

    selected = select_development_checkpoint(records)
    comparison = {
        "schema_version": 2,
        "training_run_id": training["run_id"],
        "protocol": {
            "gold": input_hash(GOLD_DEVELOPMENT),
            "gcd": "on",
            "temperature": 0.0,
            "seed": 0,
            "item_count": 60,
            "databases": [input_hash(path) for path in DEVELOPMENT_DATABASES],
            "evaluator_row_cap": 10_000,
            "selection_order": [
                "valid_sql_rate_desc",
                "ex_desc",
                "worst_tier_ex_desc",
                "p95_latency_asc",
                "iteration_asc",
            ],
        },
        "checkpoints": records,
        "selected_iteration": selected["iteration"],
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    comparison_path = comparison_directory / "comparison.json"
    write_json(comparison_path, comparison)
    evaluation_record = {
        "comparison_path": str(comparison_path.resolve()),
        "comparison_sha256": sha256_file(comparison_path),
        "checkpoints": records,
        "selected": selected,
    }
    training["checkpoint_evaluation"] = evaluation_record
    training["status"] = "local_complete"
    write_json(training_manifest_path, training)
    return evaluation_record


def main() -> None:
    args = parse_args()
    result = evaluate_training_checkpoints(
        args.training_run.resolve() / "manifest.json",
        model_manifest=args.manifest,
        models_dir=args.models_dir,
    )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
