"""Require every permanent binding regression to pass across five seeds."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, create_run_directory, sha256_file, write_json
from eval.selection import SelectionError, analysis_id, load_run

REGRESSIONS = REPO_ROOT / "eval" / "gold" / "binding_regressions.jsonl"
DEFAULT_ANALYSES = REPO_ROOT / "eval" / "analyses"


def evaluated_artifact(run) -> dict[str, str]:
    checkpoint = run.manifest.get("adapter", {}).get("checkpoint", {})
    if checkpoint.get("sha256"):
        return {
            "kind": "adapter-checkpoint",
            "sha256": checkpoint["sha256"],
        }
    model_sha256 = run.manifest.get("model", {}).get(
        "verified_directory_sha256"
    )
    if model_sha256:
        return {"kind": "model-directory", "sha256": model_sha256}
    raise SelectionError(
        f"binding run does not identify the evaluated artifact: {run.directory}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, action="append", required=True)
    parser.add_argument("--analyses-dir", type=Path, default=DEFAULT_ANALYSES)
    return parser.parse_args()


def analyze(paths: list[Path]) -> dict[str, Any]:
    if len(paths) != 5:
        raise SelectionError("binding regression gate requires exactly five seeds")
    expected_hash = sha256_file(REGRESSIONS)
    expected_items = tuple(
        json.loads(line)
        for line in REGRESSIONS.read_text().splitlines()
        if line
    )
    expected_ids = {item["id"] for item in expected_items}
    if len(expected_items) != 15 or len(expected_ids) != 15:
        raise SelectionError("binding regression fixture must contain 15 unique items")
    runs = [load_run(path.resolve()) for path in paths]
    identities = {
        (
            run.summary.get("model_key"),
            run.summary.get("gcd"),
            float(run.summary.get("temperature", -1)),
        )
        for run in runs
    }
    if (
        len(identities) != 1
        or {run.summary.get("seed") for run in runs} != set(range(5))
    ):
        raise SelectionError("binding runs must use one configuration and seeds 0...4")
    evaluated_artifacts = {tuple(evaluated_artifact(run).items()) for run in runs}
    if len(evaluated_artifacts) != 1:
        raise SelectionError("binding runs must evaluate one identical artifact")
    failures = []
    for run in runs:
        if (
            run.manifest.get("inputs", {}).get("gold", {}).get("sha256")
            != expected_hash
            or {item.get("id") for item in run.items} != expected_ids
            or len(run.items) != len(expected_ids)
        ):
            raise SelectionError(f"wrong binding regression input: {run.directory}")
        failures.extend(
            {
                "run": run.directory.name,
                "id": item["id"],
                "error": item.get("error"),
                "ex": item.get("ex"),
            }
            for item in run.items
            if item.get("error") is not None or item.get("ex") is not True
        )
    return {
        "schema_version": 1,
        "analysis": "binding-regression-gate",
        "pass": not failures,
        "model_key": runs[0].summary["model_key"],
        "gcd": runs[0].summary["gcd"],
        "temperature": runs[0].summary["temperature"],
        "seeds": list(range(5)),
        "item_count": 15,
        "checks": 75,
        "evaluated_artifact": dict(evaluated_artifacts.pop()),
        "regressions": {
            "path": REGRESSIONS.relative_to(REPO_ROOT).as_posix(),
            "sha256": expected_hash,
        },
        "failures": failures,
        "inputs": [
            {
                "path": str(run.directory),
                "manifest_sha256": sha256_file(run.directory / "manifest.json"),
            }
            for run in runs
        ],
    }


def main() -> None:
    args = parse_args()
    payload = analyze(args.run)
    if not payload["pass"]:
        raise SelectionError("one or more binding regressions failed")
    identifier = f"binding-regressions-{analysis_id(payload)}"
    directory = create_run_directory(args.analyses_dir.resolve(), identifier)
    write_json(directory / "analysis.json", payload)
    print(json.dumps({"analysis_id": identifier, **payload}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except SelectionError as error:
        raise SystemExit(f"analysis failed: {error}") from error
