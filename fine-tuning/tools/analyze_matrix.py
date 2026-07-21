"""Create immutable, rule-driven model-selection analyses.

Examples:
  uv run python -m tools.analyze_matrix screen --run ../eval/runs/<id> [...]
  uv run python -m tools.analyze_matrix gcd --run ../eval/runs/<id> [...]
  uv run python -m tools.analyze_matrix temperature --run ../eval/runs/<id> [...]
  uv run python -m tools.analyze_matrix production --run ../eval/runs/<id> [...]
  uv run python -m tools.analyze_matrix parity \
    --python-run ../eval/runs/<id> --swift-output ../eval/runs/<id>/swift.json
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, create_run_directory, sha256_file, write_json
from eval.selection import (
    Aggregate,
    SelectionError,
    aggregate,
    analysis_id,
    best_gcd,
    configurations_are_tied,
    load_run,
    production_tie_key,
    rank_key,
    temperature_is_eligible,
)

DEFAULT_ANALYSES = REPO_ROOT / "eval" / "analyses"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analyses-dir", type=Path, default=DEFAULT_ANALYSES)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("screen", "gcd", "temperature", "production"):
        command = subparsers.add_parser(name)
        command.add_argument("--run", type=Path, action="append", required=True)
    parity = subparsers.add_parser("parity")
    parity.add_argument("--python-run", type=Path, required=True)
    parity.add_argument("--swift-output", type=Path, required=True)
    parity.add_argument(
        "--explanations",
        type=Path,
        help=(
            "JSON object mapping every disagreement item ID to a non-empty "
            "evidence-based explanation"
        ),
    )
    return parser.parse_args()


def provenance(runs: list[Path]) -> list[dict[str, str]]:
    values = []
    for path in sorted(runs):
        resolved = path.resolve()
        try:
            display = resolved.relative_to(REPO_ROOT).as_posix()
        except ValueError:
            display = str(resolved)
        values.append(
            {
                "path": display,
                "manifest_sha256": sha256_file(resolved / "manifest.json"),
            }
        )
    return values


def screen(run_paths: list[Path]) -> dict[str, Any]:
    runs = [load_run(path) for path in run_paths]
    grouped: dict[str, list[Aggregate]] = defaultdict(list)
    for run in runs:
        if float(run.summary["temperature"]) != 0:
            raise SelectionError("screening accepts only temperature-0 runs")
        if run.summary["gold"] != "gold_v1.jsonl" or run.summary["n"] != 60:
            raise SelectionError("screening requires all 60 gold_v1 items")
        grouped[run.model_key].append(aggregate([run]))
    for model, configurations in grouped.items():
        if {value.gcd for value in configurations} != {"on", "off"}:
            raise SelectionError(f"{model}: screening requires GCD on and off")
    winners = [best_gcd(configurations) for configurations in grouped.values()]
    ranked = sorted(winners, key=rank_key)
    return {
        "schema_version": 1,
        "analysis": "gold-v1-base-screen",
        "selection_rule": [
            "execution accuracy",
            "valid SQL",
            "worst-tier execution accuracy",
            "p95 latency",
            "bundle size",
        ],
        "ranked_best_gcd_by_family": [
            value.metrics() for value in ranked
        ],
        "selected_model_keys": [value.model_key for value in ranked[:2]],
        "inputs": provenance(run_paths),
    }


def gcd_selection(run_paths: list[Path]) -> dict[str, Any]:
    runs = [load_run(path) for path in run_paths]
    grouped: dict[str, list[Aggregate]] = defaultdict(list)
    for run in runs:
        if (
            float(run.summary["temperature"]) != 0
            or run.summary["gold"] != "gold_v2.jsonl"
            or run.summary["n"] != 200
        ):
            raise SelectionError(
                "GCD selection requires temperature-0 runs over all 200 gold_v2 items"
            )
        grouped[run.model_key].append(aggregate([run]))
    if len(grouped) != 2:
        raise SelectionError("GCD selection requires exactly two artifacts")
    for model, configurations in grouped.items():
        if {value.gcd for value in configurations} != {"on", "off"}:
            raise SelectionError(f"{model}: GCD selection requires on and off")
    selected = [
        best_gcd(configurations)
        for _, configurations in sorted(grouped.items())
    ]
    return {
        "schema_version": 1,
        "analysis": "gold-v2-gcd-selection",
        "selection_rule": [
            "execution accuracy",
            "valid SQL",
            "worst-tier execution accuracy",
            "p95 latency",
            "bundle size",
        ],
        "selected": [value.metrics() for value in selected],
        "inputs": provenance(run_paths),
    }


def temperature(run_paths: list[Path]) -> dict[str, Any]:
    runs = [load_run(path) for path in run_paths]
    grouped: dict[tuple[str, str, float], list] = defaultdict(list)
    for run in runs:
        if run.summary["gold"] != "gold_v2.jsonl" or run.summary["n"] != 200:
            raise SelectionError(
                "temperature analysis requires all 200 gold_v2 items"
            )
        grouped[
            (
                run.model_key,
                run.summary["gcd"],
                float(run.summary["temperature"]),
            )
        ].append(run)
    configurations = [aggregate(values) for values in grouped.values()]
    identities = {(value.model_key, value.gcd) for value in configurations}
    if len(identities) != 1:
        raise SelectionError(
            "temperature analysis must contain one artifact and one GCD mode"
        )
    expected_temperatures = {0.0, 0.1, 0.3, 0.7}
    if {value.temperature for value in configurations} != expected_temperatures:
        raise SelectionError(
            "temperature analysis requires temperatures 0.0, 0.1, 0.3, and 0.7"
        )
    for configuration in configurations:
        if configuration.seeds != (0, 1, 2, 3, 4):
            raise SelectionError(
                "each temperature requires exactly seeds 0, 1, 2, 3, and 4"
            )
    baseline = next(
        (value for value in configurations if value.temperature == 0), None
    )
    if baseline is None:
        raise SelectionError("temperature analysis requires a 0.0 baseline")
    comparisons: list[dict[str, Any]] = []
    eligible = [baseline]
    for candidate in configurations:
        if candidate.temperature == 0:
            continue
        is_eligible, comparison = temperature_is_eligible(
            candidate, baseline
        )
        comparison["candidate"] = candidate.metrics()
        comparison["baseline"] = baseline.metrics()
        comparisons.append(comparison)
        if is_eligible:
            eligible.append(candidate)
    selected = sorted(
        eligible,
        key=lambda value: (
            -value.ex,
            -value.valid_sql_rate,
            value.p95_microseconds,
            value.temperature,
        ),
    )[0]
    return {
        "schema_version": 1,
        "analysis": "temperature-standardization",
        "artifact": baseline.model_key,
        "gcd": baseline.gcd,
        "configurations": [
            value.metrics()
            for value in sorted(configurations, key=lambda value: value.temperature)
        ],
        "comparisons_to_temperature_zero": comparisons,
        "selected": selected.metrics(),
        "inputs": provenance(run_paths),
    }


def production(run_paths: list[Path]) -> dict[str, Any]:
    runs = [load_run(path) for path in run_paths]
    grouped: dict[tuple[str, str, float], list] = defaultdict(list)
    for run in runs:
        if run.summary["gold"] != "gold_v2.jsonl" or run.summary["n"] != 200:
            raise SelectionError(
                "production selection requires all 200 gold_v2 items"
            )
        grouped[
            (
                run.model_key,
                run.summary["gcd"],
                float(run.summary["temperature"]),
            )
        ].append(run)
    configurations = [aggregate(values) for values in grouped.values()]
    if (
        len(configurations) != 4
        or len({value.model_key for value in configurations}) != 4
    ):
        raise SelectionError(
            "production selection requires exactly one eligible configuration "
            "for each of four artifacts"
        )
    for configuration in configurations:
        if configuration.seeds != (0, 1, 2, 3, 4):
            raise SelectionError(
                "each production configuration requires exactly seeds "
                "0, 1, 2, 3, and 4"
            )
    top_by_ex = sorted(configurations, key=lambda value: -value.ex)[0]
    tie_pool = [top_by_ex]
    comparisons: list[dict[str, Any]] = []
    for candidate in configurations:
        if candidate is top_by_ex:
            continue
        tied, comparison = configurations_are_tied(candidate, top_by_ex)
        comparison["candidate"] = candidate.metrics()
        comparison["incumbent"] = top_by_ex.metrics()
        comparisons.append(comparison)
        if tied:
            tie_pool.append(candidate)
    selected = sorted(tie_pool, key=production_tie_key)[0]
    return {
        "schema_version": 1,
        "analysis": "production-artifact-selection",
        "tie_rule": (
            "absolute EX difference under 0.02 or paired item-clustered "
            "bootstrap 95% interval contains zero"
        ),
        "tie_breaks": [
            "valid SQL",
            "worst-tier execution accuracy",
            "p95 latency",
            "bundle size",
        ],
        "configurations": [value.metrics() for value in configurations],
        "comparisons_to_top_ex": comparisons,
        "tie_pool": [value.metrics() for value in tie_pool],
        "selected": selected.metrics(),
        "inputs": provenance(run_paths),
    }


def normalize_parity_explanations(
    decoded: Any,
) -> tuple[dict[str, str], set[str]]:
    if not isinstance(decoded, dict):
        raise SelectionError("parity explanations must be a JSON object")
    raw_ids = {str(item_id) for item_id in decoded}
    if any(
        not isinstance(value, str) or not value.strip()
        for value in decoded.values()
    ):
        raise SelectionError(
            "parity explanations must contain non-empty strings"
        )
    return (
        {
            str(item_id): value.strip()
            for item_id, value in decoded.items()
        },
        raw_ids,
    )


def identical_sql_runtime_drift(
    item: dict[str, Any], python_sqlite: str, swift_sqlite: str
) -> bool:
    python_sql = item["python"]["sql"]
    return (
        python_sql is not None
        and python_sql == item["swift"]["sql"]
        and python_sqlite == swift_sqlite
    )


def parity(
    python_run_path: Path,
    swift_output_path: Path,
    explanations_path: Path | None = None,
) -> dict[str, Any]:
    python_run = load_run(python_run_path)
    swift = json.loads(swift_output_path.read_text())
    if len(python_run.items) != 200:
        raise SelectionError("parity requires all 200 gold_v2 items")
    swift_summary = swift.get("summary", {})
    swift_model = swift_summary.get("model", {})
    expected_model = python_run.manifest["model"]
    expected_configuration = python_run.manifest["configuration"]
    if (
        swift_summary.get("runtime") != "swift-mlx"
        or swift_summary.get("itemCount") != 200
        or swift_model.get("key") != python_run.model_key
        or swift_model.get("repository") != expected_model["repository"]
        or swift_model.get("revision") != expected_model["revision"]
        or swift_summary.get("gcd") != expected_configuration["gcd"]
        or float(swift_summary.get("temperature", -1))
        != float(expected_configuration["temperature"])
        or int(swift_summary.get("seed", -1))
        != int(expected_configuration["run_seed"])
        or swift_summary.get("topP") != 1
        or swift_summary.get("topK") != 0
        or swift_summary.get("maxTokens") != 512
        or swift_summary.get("rowCap") != 10_000
    ):
        raise SelectionError(
            "Swift parity configuration does not exactly match the Python run"
        )
    swift_provenance = swift.get("provenance", {})
    python_inputs = python_run.manifest["inputs"]
    python_sqlite = python_run.manifest.get("dependencies", {}).get("sqlite")
    swift_sqlite = swift_provenance.get("sqliteVersion")
    if not python_sqlite or not swift_sqlite:
        raise SelectionError(
            "both parity artifacts must persist their SQLite engine version"
        )
    if (
        swift_provenance.get("database", {}).get("sha256")
        != python_inputs["database"]["sha256"]
        or swift_provenance.get("gold", {}).get("sha256")
        != python_inputs["gold"]["sha256"]
        or swift_provenance.get("modelArtifactLock", {}).get("sha256")
        != expected_model["artifact_lock"]["sha256"]
        or swift_provenance.get("modelDirectorySHA256")
        != expected_model["directory_sha256"]
        or swift_provenance.get("grammarSHA256")
        != python_inputs["grammar"]["sha256"]
        or swift_provenance.get("systemPromptSHA256")
        != python_inputs["system_prompt_sha256"]
        or swift_provenance.get("packageLock", {}).get("sha256")
        != python_inputs["swift_package_lock"]["sha256"]
    ):
        raise SelectionError(
            "Swift parity provenance hashes do not match the Python run"
        )
    explanations: dict[str, str] = {}
    raw_explanation_ids: set[str] = set()
    if explanations_path is not None:
        decoded = json.loads(explanations_path.read_text())
        explanations, raw_explanation_ids = normalize_parity_explanations(
            decoded
        )
    python_by_id = {item["id"]: item for item in python_run.items}
    swift_by_id = {item["id"]: item for item in swift["results"]}
    if set(python_by_id) != set(swift_by_id):
        raise SelectionError("Python and Swift parity item IDs differ")
    for item_id in python_by_id:
        python_item = python_by_id[item_id]
        swift_item = swift_by_id[item_id]
        swift_item_model = swift_item.get("model", {})
        if (
            int(swift_item.get("seed", -1))
            != int(python_item["item_seed"])
            or int(swift_item.get("tier", -1))
            != int(python_item["tier"])
            or swift_item.get("goldSQL") != python_item["gold_sql"]
            or swift_item.get("gcd") != python_run.summary["gcd"]
            or float(swift_item.get("temperature", -1))
            != float(python_run.summary["temperature"])
            or swift_item_model.get("key") != python_run.model_key
            or swift_item_model.get("repository")
            != expected_model["repository"]
            or swift_item_model.get("revision")
            != expected_model["revision"]
        ):
            raise SelectionError(
                f"{item_id}: Python and Swift per-item parity inputs differ"
            )
        python_gold_digest = (python_by_id[item_id]["gold"] or {}).get(
            "digest"
        )
        if python_gold_digest != swift_by_id[item_id].get("goldDigest"):
            raise SelectionError(
                f"{item_id}: Python and Swift canonical gold digests differ"
            )
    disagreements = []
    for item_id in sorted(python_by_id):
        python_item = python_by_id[item_id]
        swift_item = swift_by_id[item_id]
        python_digest = (python_item["predicted"] or {}).get("digest")
        swift_digest = swift_item.get("predictedDigest")
        python_valid_item = python_item["error"] is None
        swift_valid_item = bool(swift_item["validSQL"])
        if (
            bool(python_item["ex"]) != bool(swift_item["ex"])
            or python_valid_item != swift_valid_item
            or python_item["predicted_sql"] != swift_item["predictedSQL"]
            or python_digest != swift_digest
        ):
            explanation = explanations.get(item_id)
            disagreements.append(
                {
                    "id": item_id,
                    "python": {
                        "ex": python_item["ex"],
                        "valid_sql": python_valid_item,
                        "sql": python_item["predicted_sql"],
                        "error": python_item["error"],
                        "digest": python_digest,
                    },
                    "swift": {
                        "ex": swift_item["ex"],
                        "valid_sql": swift_item["validSQL"],
                        "sql": swift_item["predictedSQL"],
                        "error": swift_item.get("error"),
                        "digest": swift_digest,
                    },
                    "explanation_status": (
                        "explained" if explanation is not None else "required"
                    ),
                    "explanation": explanation,
                }
            )
    # Explanations are structurally validated: they may cover only actual
    # disagreements, and identical SQL diverging on the same SQLite engine
    # is comparator or runtime drift that no explanation can excuse.
    disagreement_ids = {item["id"] for item in disagreements}
    stale_explanations = sorted(raw_explanation_ids - disagreement_ids)
    if stale_explanations:
        raise SelectionError(
            "explanations cover items that are not disagreements "
            f"(stale or wrong file): {stale_explanations}"
        )
    for item in disagreements:
        if identical_sql_runtime_drift(item, python_sqlite, swift_sqlite):
            raise SelectionError(
                f"{item['id']}: identical SQL on the same SQLite version "
                "produced different parity data; fix runtime/comparator "
                "drift instead of explaining it"
            )
    python_ex = sum(item["ex"] for item in python_run.items) / len(
        python_run.items
    )
    python_valid = sum(
        item["error"] is None for item in python_run.items
    ) / len(python_run.items)
    swift_ex = float(swift["summary"]["ex"])
    swift_valid = float(swift["summary"]["validSQLRate"])
    ex_delta = abs(swift_ex - python_ex)
    valid_delta = abs(swift_valid - python_valid)
    all_disagreements_explained = all(
        item["explanation_status"] == "explained"
        for item in disagreements
    )
    metrics_pass = ex_delta <= 0.02 and valid_delta <= 0.02
    parity_inputs: dict[str, Any] = {
        "python_run": provenance([python_run_path])[0],
        "swift_output": {
            "path": (
                swift_output_path.resolve().relative_to(REPO_ROOT).as_posix()
                if swift_output_path.resolve().is_relative_to(REPO_ROOT)
                else str(swift_output_path.resolve())
            ),
            "sha256": sha256_file(swift_output_path),
        },
    }
    if explanations_path is not None:
        parity_inputs["explanations"] = {
            "path": (
                explanations_path.resolve().relative_to(REPO_ROOT).as_posix()
                if explanations_path.resolve().is_relative_to(REPO_ROOT)
                else str(explanations_path.resolve())
            ),
            "sha256": sha256_file(explanations_path),
        }
    return {
        "schema_version": 1,
        "analysis": "python-swift-full-gold-parity",
        "n": len(python_run.items),
        "python": {"ex": python_ex, "valid_sql_rate": python_valid},
        "swift": {"ex": swift_ex, "valid_sql_rate": swift_valid},
        "runtime_versions": {
            "python_sqlite": python_sqlite,
            "swift_sqlite": swift_sqlite,
        },
        "absolute_deltas": {
            "ex": ex_delta,
            "valid_sql_rate": valid_delta,
        },
        "gate": {
            "maximum_absolute_delta": 0.02,
            "metrics_pass": metrics_pass,
            "all_disagreements_explained": all_disagreements_explained,
            "explanation_rule": (
                "every disagreement carries an explanation, explanations "
                "map only to actual disagreements, and identical-SQL "
                "divergence is refused unless the recorded SQLite engines "
                "differ; explanation prose is human-reviewed evidence, not "
                "machine-verified"
            ),
            "pass": metrics_pass and all_disagreements_explained,
        },
        "disagreements": disagreements,
        "inputs": parity_inputs,
    }


def main() -> None:
    args = parse_args()
    if args.command == "screen":
        payload = screen(args.run)
    elif args.command == "gcd":
        payload = gcd_selection(args.run)
    elif args.command == "temperature":
        payload = temperature(args.run)
    elif args.command == "production":
        payload = production(args.run)
    else:
        payload = parity(
            args.python_run,
            args.swift_output,
            args.explanations,
        )
    identifier = f"{args.command}-{analysis_id(payload)}"
    directory = create_run_directory(args.analyses_dir.resolve(), identifier)
    write_json(directory / "analysis.json", payload)
    print(json.dumps({"analysis_id": identifier, **payload}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except SelectionError as error:
        raise SystemExit(f"analysis failed: {error}") from error
