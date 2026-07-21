"""Run exactly two explicitly selected finalists through the experiment runner.

The general ``tools.run_experiment`` command owns training, checkpoint
selection, W&B synchronization, and conditional fusion. This compatibility
surface preserves the former two-finalist workflow without maintaining a
second training implementation.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eval.experiment import ExperimentConfig
from tools.run_experiment import MODELS_DIR, TRAINING_RUNS, run_experiment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model-key", action="append", required=True, help="selected base key"
    )
    parser.add_argument("--campaign-id", default="finalists-manual")
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    parser.add_argument("--training-runs-dir", type=Path, default=TRAINING_RUNS)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if len(args.model_key) != 2 or len(set(args.model_key)) != 2:
        raise SystemExit(
            "--model-key must be supplied exactly twice with distinct keys"
        )
    directories = []
    for key in args.model_key:
        config = ExperimentConfig(
            model_key=key,
            seed=424242,
            fine_tune_type="lora",
            trainable_layers="last-16",
            rank=8,
            scale_ratio=2.5,
            dropout=0.0,
            learning_rate=1e-4,
            iterations=600,
            campaign_id=args.campaign_id,
            stage="final",
        )
        directories.append(
            run_experiment(
                config,
                models_dir=args.models_dir,
                training_runs_dir=args.training_runs_dir,
            )
        )
    print(
        json.dumps(
            {"training_runs": [str(path) for path in directories]},
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
