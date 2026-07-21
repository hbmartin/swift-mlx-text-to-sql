"""Import the two historical finalist runs into W&B without mutating them."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, sha256_file, write_json
from eval.wandb_evidence import required_wandb_environment


TRAINING_RUNS = REPO_ROOT / "eval" / "training-runs"
EVALUATION_RUNS = REPO_ROOT / "eval" / "runs"
BACKFILL_RECEIPTS = REPO_ROOT / "eval" / "wandb-backfill"
TRAIN_RE = re.compile(
    r"Iter (?P<iteration>\d+): Train loss (?P<train_loss>[0-9.eE+-]+), "
    r"Learning Rate (?P<learning_rate>[0-9.eE+-]+), "
    r"It/sec (?P<iterations_per_second>[0-9.eE+-]+), "
    r"Tokens/sec (?P<tokens_per_second>[0-9.eE+-]+), "
    r"Trained Tokens (?P<trained_tokens>\d+), "
    r"Peak mem (?P<peak_memory>[0-9.eE+-]+) GB"
)
VAL_RE = re.compile(
    r"Iter (?P<iteration>\d+): Val loss (?P<val_loss>[0-9.eE+-]+), "
    r"Val took (?P<val_time>[0-9.eE+-]+)s"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--training-run",
        action="append",
        type=Path,
        help="historical training run (defaults to both committed runs)",
    )
    parser.add_argument("--receipts-dir", type=Path, default=BACKFILL_RECEIPTS)
    return parser.parse_args()


def parse_training_log(path: Path) -> list[dict[str, Any]]:
    """Recover exactly the telemetry printed by MLX-LM's trainer."""

    by_iteration: dict[int, dict[str, Any]] = {}
    text = path.read_text(errors="replace")
    for match in VAL_RE.finditer(text):
        iteration = int(match.group("iteration"))
        record = by_iteration.setdefault(iteration, {"iteration": iteration})
        record.update(
            {
                "val_loss": float(match.group("val_loss")),
                "val_time": float(match.group("val_time")),
            }
        )
    for match in TRAIN_RE.finditer(text):
        iteration = int(match.group("iteration"))
        record = by_iteration.setdefault(iteration, {"iteration": iteration})
        record.update(
            {
                "train_loss": float(match.group("train_loss")),
                "learning_rate": float(match.group("learning_rate")),
                "iterations_per_second": float(
                    match.group("iterations_per_second")
                ),
                "tokens_per_second": float(match.group("tokens_per_second")),
                "trained_tokens": int(match.group("trained_tokens")),
                "peak_memory": float(match.group("peak_memory")),
            }
        )
    return [by_iteration[key] for key in sorted(by_iteration)]


def historical_evaluations(training_run_id: str) -> list[Path]:
    matches = []
    for path in sorted(EVALUATION_RUNS.glob("*/manifest.json")):
        if training_run_id in path.read_text(errors="replace"):
            matches.append(path.parent)
    return matches


def _add_artifact_files(artifact: Any, files: list[Path]) -> None:
    for path in files:
        artifact.add_file(
            str(path),
            name=path.resolve().relative_to(REPO_ROOT).as_posix(),
        )


def import_historical_run(
    run_directory: Path,
    receipts_dir: Path,
    *,
    wandb_module: Any | None = None,
) -> dict[str, Any]:
    if wandb_module is None:
        import wandb as wandb_module  # type: ignore[no-redef]

    authority = required_wandb_environment()
    run_directory = run_directory.resolve()
    manifest_path = run_directory / "manifest.json"
    log_path = run_directory / "training.log"
    manifest_sha256_before = sha256_file(manifest_path)
    training = json.loads(manifest_path.read_text())
    if training.get("status") != "complete":
        raise RuntimeError(f"historical training run is incomplete: {run_directory}")
    run_id = training["run_id"]
    wb_run_id = "backfill-" + manifest_sha256_before[:12]
    run = wandb_module.init(
        entity=authority["entity"],
        project=authority["project"],
        id=wb_run_id,
        name=f"historical-{run_id}",
        group="historical-backfill",
        job_type="backfill",
        tags=["historical", "read-only", f"family:{training['base']['key']}"],
        config={
            "historical": True,
            "training_run_id": run_id,
            "base": training["base"],
            "configuration": training["configuration"],
            "corpus_manifest_sha256": training["corpus"]["manifest"]["sha256"],
        },
        resume="allow",
    )
    for metrics in parse_training_log(log_path):
        run.log(metrics, step=metrics["iteration"])

    evaluations = historical_evaluations(run_id)
    table = wandb_module.Table(
        columns=[
            "run_id",
            "gold",
            "gcd",
            "temperature",
            "seed",
            "n",
            "ex",
            "valid_sql_rate",
            "p95_microseconds",
        ]
    )
    evaluation_files: list[Path] = []
    for directory in evaluations:
        summary_path = directory / "summary.json"
        if not summary_path.is_file():
            continue
        summary = json.loads(summary_path.read_text())
        table.add_data(
            summary["run_id"],
            summary["gold"],
            summary["gcd"],
            summary["temperature"],
            summary["seed"],
            summary["n"],
            summary["ex"],
            summary["valid_sql_rate"],
            summary["p95_microseconds"],
        )
        evaluation_files.extend(
            path
            for path in (
                directory / "manifest.json",
                summary_path,
                directory / "items.jsonl",
            )
            if path.is_file()
        )
    run.log({"historical/evaluations": table})
    run.summary["historical/evaluation_count"] = len(evaluations)
    run.summary["historical/training_manifest_sha256"] = manifest_sha256_before

    artifact = wandb_module.Artifact(
        f"{run_id}-historical-evidence",
        type="historical-evidence",
        metadata={
            "read_only_mirror": True,
            "training_manifest_sha256": manifest_sha256_before,
            "file_sha256": {
                path.resolve().relative_to(REPO_ROOT).as_posix(): sha256_file(path)
                for path in [manifest_path, log_path, *evaluation_files]
            },
        },
    )
    _add_artifact_files(artifact, [manifest_path, log_path, *evaluation_files])
    logged = run.log_artifact(artifact)
    resolved = logged.wait() if hasattr(logged, "wait") else logged
    run.finish(exit_code=0)

    if sha256_file(manifest_path) != manifest_sha256_before:
        raise RuntimeError("historical manifest changed during read-only backfill")
    receipt = {
        "schema_version": 1,
        "status": "backfilled",
        "training_run_id": run_id,
        "training_manifest_sha256": manifest_sha256_before,
        "entity": authority["entity"],
        "project": authority["project"],
        "run_id": wb_run_id,
        "url": getattr(run, "url", None),
        "artifact": {
            "name": getattr(resolved, "name", artifact.name),
            "version": getattr(resolved, "version", None),
            "digest": getattr(resolved, "digest", None),
        },
        "evaluation_count": len(evaluations),
    }
    receipts_dir.mkdir(parents=True, exist_ok=True)
    write_json(receipts_dir / f"{run_id}.json", receipt)
    return receipt


def main() -> None:
    args = parse_args()
    directories = args.training_run or sorted(
        path.parent for path in TRAINING_RUNS.glob("*/manifest.json")
    )
    if len(directories) != 2:
        raise SystemExit("history import requires exactly two training runs")
    receipts = [
        import_historical_run(directory, args.receipts_dir.resolve())
        for directory in directories
    ]
    print(json.dumps(receipts, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
