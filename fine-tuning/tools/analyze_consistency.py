"""Verify one immutable schema-v3 bounded-policy calibration."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, create_run_directory, sha256_file, write_json
from eval.selection import SelectionError, analysis_id, load_run

DEFAULT_ANALYSES = REPO_ROOT / "eval" / "analyses"
POLICY_SCHEMA_VERSION = 3
POLICY_VERSION = "bounded-three-generation-v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, action="append", required=True)
    parser.add_argument("--analyses-dir", type=Path, default=DEFAULT_ANALYSES)
    return parser.parse_args()


def load_calibration(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    path = path.resolve()
    manifest = json.loads((path / "manifest.json").read_text())
    summary = json.loads((path / "summary.json").read_text())
    if (
        manifest.get("schema_version") != POLICY_SCHEMA_VERSION
        or summary.get("schema_version") != POLICY_SCHEMA_VERSION
        or manifest.get("policy_version") != POLICY_VERSION
        or summary.get("policy_version") != POLICY_VERSION
    ):
        raise SelectionError(
            f"{path}: policy calibration requires schema_version "
            f"{POLICY_SCHEMA_VERSION} and policy_version {POLICY_VERSION}; "
            "v1/v2 evidence is historical and cannot satisfy this gate"
        )
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
        summary.get("bounded_policy") is not True
        or summary.get("always_vote") is not False
        or summary.get("candidate_count") != 3
        or summary.get("sample_temperature") != 0.7
        or summary.get("trial_seeds") != [0, 1, 2, 3, 4]
        or summary.get("n_trials") != 1_000
    ):
        raise SelectionError(
            f"{path}: expected the bounded three-generation 0.7 policy "
            "over 200 items × five seeds"
        )
    if not isinstance(manifest.get("hardware"), dict) or not manifest["hardware"]:
        raise SelectionError(
            f"{path}: schema-v3 latency evidence requires frozen same-hardware provenance"
        )
    return manifest, summary


def analyze(run_paths: list[Path]) -> dict[str, Any]:
    if len(run_paths) != 1:
        raise SelectionError("policy analysis requires exactly one schema-v3 run")
    loaded = [load_calibration(path) for path in run_paths]
    summaries = [summary for _, summary in loaded]
    identities = {(item["model_key"], item["gcd"]) for item in summaries}
    if len(identities) != 1:
        raise SelectionError("calibrations must use one artifact and one GCD mode")
    selected = summaries[0]
    return {
        "schema_version": POLICY_SCHEMA_VERSION,
        "policy_version": POLICY_VERSION,
        "analysis": "bounded-three-generation-calibration",
        "hardware": loaded[0][0]["hardware"],
        "release_gates": {
            "valid_sql_rate_at_least": 0.99,
            "p95_latency_microseconds_at_most": 10_990_000,
        },
        "release_gate_passed": (
            float(selected["valid_sql_rate"]) >= 0.99
            and int(selected["p95_latency_microseconds"]) <= 10_990_000
        ),
        "configurations": summaries,
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
