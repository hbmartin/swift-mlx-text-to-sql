"""Create an immutable eligibility receipt before campaign confirmation."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from statistics import mean
from typing import Any

from eval.run_artifacts import REPO_ROOT, sha256_file, write_json


GATES = REPO_ROOT / "fine-tuning" / "config" / "promotion-gates.json"
ANALYSIS = "reliability-v3-promotion-eligibility"
SCHEMA_VERSION = 1
BOOTSTRAP_SEED = 424242
BOOTSTRAP_SAMPLES = 10_000


class PromotionEligibilityError(RuntimeError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def read_items(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text().splitlines()
        if line.strip()
    ]


def evaluation_metrics(items: list[dict[str, Any]]) -> dict[str, float]:
    if not items:
        raise PromotionEligibilityError("evaluation items are empty")
    tier3 = [item for item in items if int(item["tier"]) == 3]
    if not tier3:
        raise PromotionEligibilityError("evaluation has no tier-3 items")
    return {
        "ex": mean(bool(item["ex"]) for item in items),
        "valid_sql_rate": mean(item.get("error") is None for item in items),
        "tier3_ex": mean(bool(item["ex"]) for item in tier3),
        "wrong_table_or_join_rate": mean(
            item.get("bucket") == "wrong-table-or-join" for item in items
        ),
    }


def paired_ex_lower_bound(
    candidate: list[dict[str, Any]],
    baseline: list[dict[str, Any]],
    *,
    confidence: float,
) -> float:
    candidate_by_id = {item["id"]: bool(item["ex"]) for item in candidate}
    baseline_by_id = {item["id"]: bool(item["ex"]) for item in baseline}
    if set(candidate_by_id) != set(baseline_by_id):
        raise PromotionEligibilityError(
            "candidate and baseline must contain the same evaluation item IDs"
        )
    differences = [
        int(candidate_by_id[item_id]) - int(baseline_by_id[item_id])
        for item_id in sorted(candidate_by_id)
    ]
    rng = random.Random(BOOTSTRAP_SEED)
    samples = sorted(
        mean(rng.choice(differences) for _ in differences)
        for _ in range(BOOTSTRAP_SAMPLES)
    )
    index = max(0, round((1 - confidence) * (len(samples) - 1)))
    return samples[index]


def selected_evaluation(training_manifest: dict[str, Any]) -> tuple[dict, Path]:
    if training_manifest.get("status") != "complete":
        raise PromotionEligibilityError("candidate training run is incomplete")
    selected = training_manifest.get("checkpoint_evaluation", {}).get("selected")
    if not selected:
        raise PromotionEligibilityError("candidate has no selected checkpoint")
    items_path = Path(selected["items_path"]).resolve()
    summary = selected["summary"]
    return summary, items_path


def validate_binding(binding: dict[str, Any], candidate: dict[str, Any], gates: dict) -> None:
    expected = gates["binding"]
    experiment = candidate["experiment"]
    selected_checkpoint = candidate["checkpoint_evaluation"]["selected"][
        "checkpoint_sha256"
    ]
    if (
        binding.get("analysis") != "binding-regression-gate"
        or binding.get("schema_version") != 1
        or binding.get("pass") is not True
        or binding.get("item_count") != expected["item_count"]
        or binding.get("seeds") != expected["seeds"]
        or binding.get("checks") != expected["checks"]
        or binding.get("model_key") != experiment["model_key"]
        or binding.get("gcd") != gates["baseline"]["gcd"]
        or float(binding.get("temperature", -1))
        != float(gates["baseline"]["temperature"])
        or binding.get("evaluated_artifact")
        != {
            "kind": "adapter-checkpoint",
            "sha256": selected_checkpoint,
        }
    ):
        raise PromotionEligibilityError(
            "binding receipt is incomplete or does not match the candidate"
        )


def analyze(
    candidate_manifest_path: Path,
    binding_path: Path,
    baseline_run: Path,
    *,
    gates_path: Path = GATES,
) -> dict[str, Any]:
    candidate_manifest_path = candidate_manifest_path.resolve()
    binding_path = binding_path.resolve()
    baseline_run = baseline_run.resolve()
    gates_path = gates_path.resolve()
    candidate = read_json(candidate_manifest_path)
    binding = read_json(binding_path)
    gates = read_json(gates_path)
    if gates.get("schema_version") != 1:
        raise PromotionEligibilityError("unsupported promotion gate schema")
    validate_binding(binding, candidate, gates)

    candidate_summary, candidate_items_path = selected_evaluation(candidate)
    baseline_manifest_path = baseline_run / "manifest.json"
    baseline_summary_path = baseline_run / "summary.json"
    baseline_items_path = baseline_run / "items.jsonl"
    baseline_manifest = read_json(baseline_manifest_path)
    baseline_summary = read_json(baseline_summary_path)
    if baseline_manifest.get("status") != "complete":
        raise PromotionEligibilityError("selection-safe baseline run is incomplete")
    expected_gold = gates["selection_dataset"]
    if (
        candidate_summary.get("gold") != expected_gold
        or baseline_summary.get("gold") != expected_gold
    ):
        raise PromotionEligibilityError("promotion inputs must use gold_v1")
    baseline_contract = gates["baseline"]
    if (
        baseline_summary.get("model_key") != baseline_contract["model_key"]
        or baseline_summary.get("gcd") != baseline_contract["gcd"]
        or float(baseline_summary.get("temperature", -1))
        != float(baseline_contract["temperature"])
        or candidate_summary.get("gcd") != baseline_contract["gcd"]
        or float(candidate_summary.get("temperature", -1))
        != float(baseline_contract["temperature"])
    ):
        raise PromotionEligibilityError(
            "promotion must compare against the pinned production baseline protocol"
        )
    minimum_snapshots = gates["minimum_snapshot_count"]
    if (
        int(candidate_summary.get("snapshot_count", 0)) < minimum_snapshots
        or int(baseline_summary.get("snapshot_count", 0)) < minimum_snapshots
        or candidate_summary.get("database_set_sha256")
        != baseline_summary.get("database_set_sha256")
    ):
        raise PromotionEligibilityError(
            "candidate and baseline must use the same multi-snapshot database set"
        )

    candidate_items = read_items(candidate_items_path)
    baseline_items = read_items(baseline_items_path)
    candidate_metrics = evaluation_metrics(candidate_items)
    baseline_metrics = evaluation_metrics(baseline_items)
    thresholds = gates["single_shot"]
    lower_bound = paired_ex_lower_bound(
        candidate_items,
        baseline_items,
        confidence=float(thresholds["ex_confidence"]),
    )
    wrong_join_ceiling = min(
        float(thresholds["maximum_wrong_table_or_join_rate"]),
        baseline_metrics["wrong_table_or_join_rate"],
    )
    checks = {
        "binding_15_by_5": True,
        "ex_noninferior": lower_bound
        >= -float(thresholds["ex_noninferiority_margin"]),
        "valid_sql_noninferior": candidate_metrics["valid_sql_rate"]
        >= baseline_metrics["valid_sql_rate"]
        - float(thresholds["valid_sql_noninferiority_margin"]),
        "tier3_materially_better": candidate_metrics["tier3_ex"]
        >= baseline_metrics["tier3_ex"]
        + float(thresholds["minimum_tier3_absolute_improvement"]),
        "wrong_table_or_join_within_ceiling": candidate_metrics[
            "wrong_table_or_join_rate"
        ]
        <= wrong_join_ceiling,
    }
    experiment = candidate["experiment"]
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "analysis": ANALYSIS,
        "candidate_run_id": candidate["run_id"],
        "recipe": f"{experiment['model_key']}:{experiment['configuration_sha256']}",
        "model_key": experiment["model_key"],
        "selected_checkpoint_sha256": candidate["checkpoint_evaluation"][
            "selected"
        ]["checkpoint_sha256"],
        "selection_dataset": expected_gold,
        "database_set_sha256": candidate_summary["database_set_sha256"],
        "candidate_metrics": candidate_metrics,
        "baseline_metrics": baseline_metrics,
        "paired_ex_difference_lower_bound": lower_bound,
        "wrong_table_or_join_ceiling": wrong_join_ceiling,
        "thresholds": thresholds,
        "checks": checks,
        "pass": all(checks.values()),
        "inputs": {
            "candidate_manifest": {
                "path": str(candidate_manifest_path),
                "sha256": sha256_file(candidate_manifest_path),
            },
            "candidate_items": {
                "path": str(candidate_items_path),
                "sha256": sha256_file(candidate_items_path),
            },
            "binding": {
                "path": str(binding_path),
                "sha256": sha256_file(binding_path),
            },
            "baseline_manifest": {
                "path": str(baseline_manifest_path),
                "sha256": sha256_file(baseline_manifest_path),
            },
            "baseline_summary": {
                "path": str(baseline_summary_path),
                "sha256": sha256_file(baseline_summary_path),
            },
            "baseline_items": {
                "path": str(baseline_items_path),
                "sha256": sha256_file(baseline_items_path),
            },
            "gates": {"path": str(gates_path), "sha256": sha256_file(gates_path)},
        },
        "release_policy_valid_sql_rate": gates["full_policy_release"][
            "minimum_valid_sql_rate"
        ],
    }
    return receipt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-training-run", type=Path, required=True)
    parser.add_argument("--binding-analysis", type=Path, required=True)
    parser.add_argument("--baseline-run", type=Path, required=True)
    parser.add_argument("--gates", type=Path, default=GATES)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    candidate_manifest = args.candidate_training_run.resolve()
    if candidate_manifest.is_dir():
        candidate_manifest = candidate_manifest / "manifest.json"
    result = analyze(
        candidate_manifest,
        args.binding_analysis,
        args.baseline_run,
        gates_path=args.gates,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_json(args.output, result)
    print(json.dumps(result, indent=2, sort_keys=True))
    if not result["pass"]:
        raise SystemExit("candidate is not eligible for confirmation")


if __name__ == "__main__":
    main()
