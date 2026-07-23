"""Create the eight-run confirmation plan or select the final campaign recipe."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eval.campaign import (
    load_eligibility,
    load_experiment_manifest,
    promotion_plan,
    select_campaign_winner,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["plan-promotions", "select-winner"])
    parser.add_argument("--training-run", action="append", type=Path, required=True)
    parser.add_argument(
        "--eligibility", action="append", type=Path, required=True
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifests = [load_experiment_manifest(path.resolve()) for path in args.training_run]
    eligibility = [load_eligibility(path.resolve()) for path in args.eligibility]
    result = (
        promotion_plan(manifests, eligibility)
        if args.phase == "plan-promotions"
        else select_campaign_winner(manifests, eligibility)
    )
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
