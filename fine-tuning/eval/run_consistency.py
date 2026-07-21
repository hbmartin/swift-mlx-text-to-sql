"""Calibrate N=3 always-vote self-consistency for the production winner.

Each trial executes one temperature-zero anchor and two candidates at the
requested sample temperature. Five trial seeds are run for 0.1, 0.3, and 0.7.
Underlying single-candidate Evaluation Runs remain immutable evidence.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from eval.prompt_contract import build_system_prompt
from eval.run_artifacts import (
    DEFAULT_RUNS_DIR,
    REPO_ROOT,
    create_run_directory,
    percentile,
    sha256_bytes,
    sha256_file,
    write_json,
)
from eval.selection import Run, SelectionError, load_run
from tools.fetch_model import load_manifest

GOLD_V2 = REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
DATABASE = REPO_ROOT / "db" / "creg.sqlite"
GRAMMAR = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "sql_grammar.ebnf"
)
SCHEMA_PROMPT = (
    REPO_ROOT
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "schema_prompt.txt"
)
SWIFT_LOCK = REPO_ROOT / "CREGKit" / "Package.resolved"
UV_LOCK = REPO_ROOT / "fine-tuning" / "uv.lock"
DEFAULT_CONSISTENCY = REPO_ROOT / "eval" / "consistency-runs"
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-key", required=True)
    parser.add_argument("--gcd", choices=["on", "off"], required=True)
    parser.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR)
    parser.add_argument(
        "--consistency-runs-dir", type=Path, default=DEFAULT_CONSISTENCY
    )
    return parser.parse_args()


def run_id(model: str, gcd: str, temperature: float, seed: int) -> str:
    return (
        f"consistency-source-{model}-gcd-{gcd}-"
        f"t-{str(temperature).replace('.', '_')}-s-{seed}"
    )


def run_is_compatible(
    run: Run,
    *,
    model: str,
    repository: str,
    revision: str,
    gcd: str,
    temperature: float,
    seed: int,
    gold_sha256: str,
    input_sha256: dict[str, str] | None = None,
    artifact_lock_sha256: str | None = None,
    directory_sha256: str | None = None,
) -> bool:
    """Return whether an immutable Evaluation Run is the exact required cell."""
    configuration = run.manifest.get("configuration", {})
    model_identity = run.manifest.get("model", {})
    gold = run.manifest.get("inputs", {}).get("gold", {})
    compatible = (
        run.summary.get("model_key") == model
        and model_identity.get("repository") == repository
        and model_identity.get("revision") == revision
        and run.summary.get("gcd") == gcd
        and float(run.summary.get("temperature", -1)) == temperature
        and int(run.summary.get("seed", -1)) == seed
        and gold.get("sha256") == gold_sha256
        and int(run.summary.get("n", -1)) == 200
        and configuration.get("top_p") == 1.0
        and configuration.get("top_k") == 0
        and configuration.get("max_tokens") == 512
        and configuration.get("item_seed_formula")
        == "run_seed * 1000000 + zero_based_item_index"
    )
    if not compatible:
        return False
    inputs = run.manifest.get("inputs", {})
    if input_sha256 is not None:
        for name, expected in input_sha256.items():
            if name == "system_prompt_sha256":
                if inputs.get(name) != expected:
                    return False
            elif inputs.get(name, {}).get("sha256") != expected:
                return False
    if (
        artifact_lock_sha256 is not None
        and model_identity.get("artifact_lock", {}).get("sha256")
        != artifact_lock_sha256
    ):
        return False
    return (
        directory_sha256 is None
        or model_identity.get("directory_sha256") == directory_sha256
    )


def find_compatible_run(
    *,
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
    runs_dir: Path,
) -> Path | None:
    """Find verified prior evidence instead of regenerating an identical cell."""
    manifest = load_manifest(MODEL_MANIFEST)
    artifact = next(
        (item for item in manifest["models"] if item["key"] == model), None
    )
    if artifact is None:
        raise SelectionError(f"model is not declared in the manifest: {model}")
    repository = artifact.get("repository")
    revision = artifact.get("revision")
    if not repository or not revision:
        # Local-only artifacts cannot be identified independently of a path.
        return None
    conversion = artifact.get("conversion")
    local_directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    model_directory = REPO_ROOT / "models" / local_directory
    artifact_lock = model_directory / ".creg-artifact.json"
    tokenizer = model_directory / "tokenizer.json"
    if not artifact_lock.is_file() or not tokenizer.is_file():
        return None
    lock_payload = json.loads(artifact_lock.read_text())
    input_sha256 = {
        "database": sha256_file(DATABASE),
        "gold": sha256_file(GOLD_V2),
        "grammar": sha256_file(GRAMMAR),
        "schema_prompt": sha256_file(SCHEMA_PROMPT),
        "swift_package_lock": sha256_file(SWIFT_LOCK),
        "uv_lock": sha256_file(UV_LOCK),
        "tokenizer": sha256_file(tokenizer),
        "system_prompt_sha256": sha256_bytes(
            build_system_prompt(SCHEMA_PROMPT.read_text().strip()).encode()
        ),
    }

    for directory in sorted(path for path in runs_dir.iterdir() if path.is_dir()):
        try:
            run = load_run(directory)
        except (OSError, ValueError, KeyError, SelectionError):
            continue
        if run_is_compatible(
            run,
            model=model,
            repository=repository,
            revision=revision,
            gcd=gcd,
            temperature=temperature,
            seed=seed,
            gold_sha256=sha256_file(GOLD_V2),
            input_sha256=input_sha256,
            artifact_lock_sha256=sha256_file(artifact_lock),
            directory_sha256=lock_payload.get("directory_sha256"),
        ):
            return directory
    return None


def ensure_run(
    model: str,
    gcd: str,
    temperature: float,
    seed: int,
    runs_dir: Path,
) -> Path:
    identifier = run_id(model, gcd, temperature, seed)
    directory = runs_dir / identifier
    if directory.exists():
        load_run(directory)
        return directory
    reusable = find_compatible_run(
        model=model,
        gcd=gcd,
        temperature=temperature,
        seed=seed,
        runs_dir=runs_dir,
    )
    if reusable is not None:
        print(f"Reusing compatible immutable run: {reusable}")
        return reusable
    subprocess.run(
        [
            sys.executable,
            "-m",
            "eval.run_eval",
            "--model-key",
            model,
            "--gold",
            str(GOLD_V2),
            "--gcd",
            gcd,
            "--temperature",
            str(temperature),
            "--seed",
            str(seed),
            "--run-id",
            identifier,
            "--runs-dir",
            str(runs_dir),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    return directory


def complete_candidate(item: dict[str, Any]) -> bool:
    predicted = item.get("predicted")
    return (
        item.get("error") is None
        and predicted is not None
        and not predicted["is_truncated"]
        and predicted["digest"] is not None
    )


def main() -> None:
    args = parse_args()
    runs_dir = args.runs_dir.resolve()
    anchor_path = ensure_run(
        args.model_key, args.gcd, 0.0, 0, runs_dir
    )
    anchor = load_run(anchor_path)
    anchor_items = {item["id"]: item for item in anchor.items}

    for sample_temperature in (0.1, 0.3, 0.7):
        source_paths = [anchor_path]
        samples = {}
        for seed in range(10):
            path = ensure_run(
                args.model_key,
                args.gcd,
                sample_temperature,
                seed,
                runs_dir,
            )
            source_paths.append(path)
            samples[seed] = {
                item["id"]: item for item in load_run(path).items
            }

        identifier = (
            f"n3-{args.model_key}-gcd-{args.gcd}-"
            f"sample-t-{str(sample_temperature).replace('.', '_')}"
        )
        directory = create_run_directory(
            args.consistency_runs_dir.resolve(), identifier
        )
        records = []
        for trial_seed in range(5):
            for item_id in sorted(anchor_items):
                candidates = [
                    ("anchor", anchor_items[item_id]),
                    ("sample-1", samples[trial_seed * 2][item_id]),
                    ("sample-2", samples[trial_seed * 2 + 1][item_id]),
                ]
                groups = Counter(
                    item["predicted"]["digest"]
                    for _, item in candidates
                    if complete_candidate(item)
                )
                majority = next(
                    (
                        (digest, count)
                        for digest, count in sorted(groups.items())
                        if count >= 2
                    ),
                    None,
                )
                anchor_ok = complete_candidate(candidates[0][1])
                outcome: str
                selected: tuple[str, dict[str, Any]] | None
                agreement = 0
                if majority is not None:
                    digest, agreement = majority
                    selected = next(
                        candidate
                        for candidate in candidates
                        if complete_candidate(candidate[1])
                        and candidate[1]["predicted"]["digest"] == digest
                    )
                    outcome = "consensus"
                elif anchor_ok:
                    selected = candidates[0]
                    outcome = "no-consensus"
                else:
                    selected = next(
                        (
                            candidate
                            for candidate in candidates[1:]
                            if complete_candidate(candidate[1])
                        ),
                        None,
                    )
                    outcome = "anchor-failed"
                records.append(
                    {
                        "schema_version": 1,
                        "id": item_id,
                        "trial_seed": trial_seed,
                        "sample_temperature": sample_temperature,
                        "outcome": outcome,
                        "agreement": agreement,
                        "anchor_failed": not anchor_ok,
                        "selected_role": (
                            selected[0] if selected is not None else None
                        ),
                        "ex": (
                            bool(selected[1]["ex"])
                            if selected is not None
                            else False
                        ),
                        "valid_sql": (
                            selected[1]["error"] is None
                            if selected is not None
                            else False
                        ),
                        "latency_microseconds": sum(
                            int(item["elapsed_microseconds"])
                            for _, item in candidates
                        ),
                        "candidates": [
                            {
                                "role": role,
                                "run_seed": item["run_seed"],
                                "item_seed": item["item_seed"],
                                "sql": item["predicted_sql"],
                                "error": item["error"],
                                "result": item["predicted"],
                                "ex": item["ex"],
                                "elapsed_microseconds": item[
                                    "elapsed_microseconds"
                                ],
                            }
                            for role, item in candidates
                        ],
                    }
                )

        items_path = directory / "items.jsonl"
        with items_path.open("x") as output:
            for record in records:
                output.write(
                    json.dumps(
                        record,
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
        timings = [record["latency_microseconds"] for record in records]
        count = len(records)
        outcomes = Counter(record["outcome"] for record in records)
        summary = {
            "schema_version": 1,
            "model_key": args.model_key,
            "gcd": args.gcd,
            "always_vote": True,
            "candidate_count": 3,
            "sample_temperature": sample_temperature,
            "trial_seeds": list(range(5)),
            "n_trials": count,
            "ex": sum(record["ex"] for record in records) / count,
            "valid_sql_rate": (
                sum(record["valid_sql"] for record in records) / count
            ),
            "consensus": outcomes["consensus"],
            "no_consensus": outcomes["no-consensus"],
            "anchor_failures": sum(
                record["anchor_failed"] for record in records
            ),
            "mean_latency_microseconds": round(sum(timings) / count),
            "p95_latency_microseconds": percentile(timings, 0.95),
        }
        write_json(directory / "summary.json", summary)
        manifest = {
            "schema_version": 1,
            "run_id": identifier,
            "status": "complete",
            "configuration": {
                "always_vote": True,
                "candidate_count": 3,
                "anchor_temperature": 0.0,
                "sample_temperature": sample_temperature,
                "trial_seeds": list(range(5)),
                "top_p": 1.0,
                "top_k": 0,
                "max_tokens": 512,
            },
            "sources": [
                {
                    "path": str(path),
                    "manifest_sha256": sha256_file(
                        path / "manifest.json"
                    ),
                }
                for path in source_paths
            ],
            "outputs": {
                "items": {
                    "path": "items.jsonl",
                    "sha256": sha256_file(items_path),
                },
                "summary": {
                    "path": "summary.json",
                    "sha256": sha256_file(directory / "summary.json"),
                },
            },
        }
        write_json(directory / "manifest.json", manifest)
        print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
