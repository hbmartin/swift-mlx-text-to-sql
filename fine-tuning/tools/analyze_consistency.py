"""Select the N=3 always-vote sample temperature from immutable calibrations.

Exactly one complete calibration for each sample temperature (0.1, 0.3, and
0.7) is required. The analysis never silently accepts a partial run.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, create_run_directory, sha256_file, write_json
from eval.selection import SelectionError, analysis_id, load_run

DEFAULT_ANALYSES = REPO_ROOT / "eval" / "analyses"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, action="append", required=True)
    parser.add_argument("--analyses-dir", type=Path, default=DEFAULT_ANALYSES)
    return parser.parse_args()


def load_calibration(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    path = path.resolve()
    manifest = json.loads((path / "manifest.json").read_text())
    summary = json.loads((path / "summary.json").read_text())
    if manifest.get("status") != "complete":
        raise SelectionError(f"consistency calibration is not complete: {path}")
    for name in ("items", "summary"):
        output = manifest.get("outputs", {}).get(name, {})
        output_path = path / output.get("path", "")
        if not output_path.is_file() or sha256_file(output_path) != output.get(
            "sha256"
        ):
            raise SelectionError(f"{path}: {name} output hash mismatch")
    if (
        summary.get("always_vote") is not True
        or summary.get("candidate_count") != 3
        or summary.get("trial_seeds") != [0, 1, 2, 3, 4]
        or summary.get("n_trials") != 1_000
    ):
        raise SelectionError(
            f"{path}: expected N=3 always-vote over 200 items × five seeds"
        )
    return manifest, summary


def analyze(run_paths: list[Path]) -> dict[str, Any]:
    if len(run_paths) != 3:
        raise SelectionError("consistency analysis requires exactly three runs")
    loaded = [load_calibration(path) for path in run_paths]
    summaries = [summary for _, summary in loaded]
    identities = {(item["model_key"], item["gcd"]) for item in summaries}
    if len(identities) != 1:
        raise SelectionError("calibrations must use one artifact and one GCD mode")
    if {float(item["sample_temperature"]) for item in summaries} != {
        0.1,
        0.3,
        0.7,
    }:
        raise SelectionError(
            "calibrations must cover sample temperatures 0.1, 0.3, and 0.7"
        )

    ranked = sorted(
        summaries,
        key=lambda item: (
            -float(item["ex"]),
            -float(item["valid_sql_rate"]),
            int(item["anchor_failures"]),
            -int(item["consensus"]),
            int(item["p95_latency_microseconds"]),
            float(item["sample_temperature"]),
        ),
    )
    selected = ranked[0]
    return {
        "schema_version": 1,
        "analysis": "n3-always-vote-calibration",
        "selection_rule": [
            "execution accuracy",
            "valid SQL",
            "fewer anchor failures",
            "more consensus outcomes",
            "p95 latency",
            "lower sample temperature",
        ],
        "configurations": sorted(
            summaries, key=lambda item: float(item["sample_temperature"])
        ),
        "selected": selected,
        "inputs": [
            {
                "path": (
                    path.resolve().relative_to(REPO_ROOT).as_posix()
                    if path.resolve().is_relative_to(REPO_ROOT)
                    else str(path.resolve())
                ),
                "manifest_sha256": sha256_file(
                    path.resolve() / "manifest.json"
                ),
            }
            for path in sorted(run_paths)
        ],
    }


def main() -> None:
    args = parse_args()
    payload = analyze(args.run)
    identifier = f"consistency-{analysis_id(payload)}"
    directory = create_run_directory(
        args.analyses_dir.resolve(), identifier
    )
    write_json(directory / "analysis.json", payload)
    print(json.dumps({"analysis_id": identifier, **payload}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except SelectionError as error:
        raise SystemExit(f"analysis failed: {error}") from error
