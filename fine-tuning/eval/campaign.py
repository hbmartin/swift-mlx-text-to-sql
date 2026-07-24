"""Promotion planning and held-out-safe campaign winner selection."""

from __future__ import annotations

import json
import hashlib
from collections import defaultdict
from pathlib import Path
from statistics import mean
from typing import Any, Iterable

from eval.experiment import checkpoint_rank_key
from eval.run_artifacts import percentile, sha256_file


CAMPAIGN_SELECTION_SCHEMA_VERSION = 2
CAMPAIGN_SELECTION_ANALYSIS = "reliability-v3-campaign-selection"
PROMOTION_ELIGIBILITY_ANALYSIS = "reliability-v3-promotion-eligibility"


CONFIRMATION_SEEDS = (424240, 424241, 424242)
LOCKED_PRODUCTION_GCD = "on"
LOCKED_PRODUCTION_TEMPERATURE = 0.0
MINIMUM_PRODUCTION_EX = 0.668


class CampaignSelectionError(RuntimeError):
    pass


def load_experiment_manifest(path: Path) -> dict[str, Any]:
    manifest_path = path / "manifest.json" if path.is_dir() else path
    payload = json.loads(manifest_path.read_text())
    if payload.get("status") != "complete":
        raise CampaignSelectionError(f"experiment is incomplete: {manifest_path}")
    selected = payload.get("checkpoint_evaluation", {}).get("selected")
    if not selected or selected.get("summary", {}).get("gold") != "gold_v1.jsonl":
        raise CampaignSelectionError(
            f"experiment lacks a selected gold_v1 checkpoint: {manifest_path}"
        )
    payload["_manifest_path"] = str(manifest_path.resolve())
    return payload


def load_eligibility(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    payload["_eligibility_path"] = str(path.resolve())
    return payload


def eligibility_index(receipts: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for receipt in receipts:
        run_id = receipt.get("candidate_run_id")
        if not isinstance(run_id, str) or run_id in result:
            raise CampaignSelectionError("duplicate or invalid eligibility receipt")
        result[run_id] = receipt
    return result


def validate_eligibility(
    manifest: dict[str, Any], receipts: dict[str, dict[str, Any]]
) -> dict[str, Any] | None:
    receipt = receipts.get(manifest["run_id"])
    if receipt is None:
        return None
    selected = manifest["checkpoint_evaluation"]["selected"]
    if (
        receipt.get("schema_version") != 1
        or receipt.get("analysis") != PROMOTION_ELIGIBILITY_ANALYSIS
        or receipt.get("pass") is not True
        or receipt.get("recipe") != recipe_identity(manifest)
        or receipt.get("model_key") != manifest["experiment"]["model_key"]
        or receipt.get("selected_checkpoint_sha256")
        != selected.get("checkpoint_sha256")
    ):
        raise CampaignSelectionError(
            f"invalid promotion eligibility for {manifest['run_id']}"
        )
    return receipt


def recipe_identity(manifest: dict[str, Any]) -> str:
    experiment = manifest["experiment"]
    return f"{experiment['model_key']}:{experiment['configuration_sha256']}"


def top_screening_recipes(
    manifests: Iterable[dict[str, Any]],
    eligibility_receipts: Iterable[dict[str, Any]],
    *,
    per_family: int = 2,
) -> dict[str, list[dict[str, Any]]]:
    receipts = eligibility_index(eligibility_receipts)
    by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    expected_families: set[str] = set()
    for manifest in manifests:
        experiment = manifest["experiment"]
        if experiment["stage"] != "screening" or experiment["seed"] != 424242:
            raise CampaignSelectionError(
                "promotion inputs must be seed-424242 screening runs"
            )
        expected_families.add(experiment["model_key"])
        if validate_eligibility(manifest, receipts) is not None:
            by_family[experiment["model_key"]].append(manifest)
    result = {}
    for family in sorted(expected_families):
        choices = by_family[family]
        ranked = sorted(
            choices,
            key=lambda item: (
                checkpoint_rank_key(item["checkpoint_evaluation"]["selected"]),
                recipe_identity(item),
            ),
            reverse=True,
        )
        result[family] = ranked[:per_family]
        if len(result[family]) != per_family:
            raise CampaignSelectionError(
                f"{family} has fewer than {per_family} promotion-eligible recipes"
            )
    return result


def promotion_plan(
    manifests: Iterable[dict[str, Any]],
    eligibility_receipts: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    receipts = list(eligibility_receipts)
    selected = top_screening_recipes(manifests, receipts)
    confirmations = []
    for family in sorted(selected):
        for manifest in selected[family]:
            experiment = manifest["experiment"]
            for seed in CONFIRMATION_SEEDS:
                confirmations.append(
                    {
                        "model_key": family,
                        "configuration_sha256": experiment["configuration_sha256"],
                        "seed": seed,
                        "reuse_run_id": (
                            manifest["run_id"] if seed == 424242 else None
                        ),
                        "configuration": {
                            key: experiment[key]
                            for key in (
                                "fine_tune_type",
                                "trainable_layers",
                                "rank",
                                "scale_ratio",
                                "dropout",
                                "learning_rate",
                                "iterations",
                                "repair_fraction",
                            )
                        },
                    }
                )
    return {
        "screening_runs": sum(len(items) for items in selected.values()),
        "promoted_seed_results": len(confirmations),
        "additional_training_runs": sum(
            item["reuse_run_id"] is None for item in confirmations
        ),
        "confirmations": confirmations,
        "eligibility_run_ids": sorted(
            receipt["candidate_run_id"] for receipt in receipts
        ),
    }


def _selected_items(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    path = Path(manifest["checkpoint_evaluation"]["selected"]["items_path"])
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def aggregate_recipe(manifests: list[dict[str, Any]]) -> dict[str, Any]:
    seeds = sorted(item["experiment"]["seed"] for item in manifests)
    if seeds != list(CONFIRMATION_SEEDS):
        raise CampaignSelectionError(
            f"recipe requires seeds {CONFIRMATION_SEEDS}, received {seeds}"
        )
    by_item: dict[str, list[bool]] = defaultdict(list)
    by_tier: dict[str, list[bool]] = defaultdict(list)
    valid: list[bool] = []
    timings: list[int] = []
    wrong_table_or_join: list[bool] = []
    for manifest in manifests:
        for item in _selected_items(manifest):
            by_item[item["id"]].append(bool(item["ex"]))
            by_tier[str(item["tier"])].append(bool(item["ex"]))
            valid.append(item["error"] is None)
            wrong_table_or_join.append(
                item.get("bucket") == "wrong-table-or-join"
            )
            timings.append(int(item["elapsed_microseconds"]))
    tier_ex = {tier: mean(values) for tier, values in sorted(by_tier.items())}
    return {
        "recipe": recipe_identity(manifests[0]),
        "model_key": manifests[0]["experiment"]["model_key"],
        "artifact_model_key": f"ft-{next(item['run_id'] for item in manifests if item['experiment']['seed'] == 424242)}",
        "gcd": LOCKED_PRODUCTION_GCD,
        "temperature": LOCKED_PRODUCTION_TEMPERATURE,
        "configuration_sha256": manifests[0]["experiment"]["configuration_sha256"],
        "item_clustered_ex": mean(mean(values) for values in by_item.values()),
        "valid_sql_rate": mean(valid),
        "wrong_table_or_join_rate": mean(wrong_table_or_join),
        "ex_by_tier": tier_ex,
        "worst_tier_ex": min(tier_ex.values(), default=0.0),
        "p95_microseconds": percentile(timings, 0.95),
        "trainable_parameter_count": max(
            int(item["trainable_parameter_count"]) for item in manifests
        ),
        "canonical_seed_run_id": next(
            item["run_id"] for item in manifests if item["experiment"]["seed"] == 424242
        ),
    }


def select_campaign_winner(
    manifests: Iterable[dict[str, Any]],
    eligibility_receipts: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for manifest in manifests:
        grouped[recipe_identity(manifest)].append(manifest)
    if len(grouped) != 4 or sum(map(len, grouped.values())) != 12:
        raise CampaignSelectionError(
            "winner selection requires four recipes and 12 promoted seed-results"
        )
    receipts = eligibility_index(eligibility_receipts)
    used_receipts = []
    for recipe, recipe_manifests in grouped.items():
        canonical = next(
            (
                item
                for item in recipe_manifests
                if item["experiment"]["seed"] == 424242
            ),
            None,
        )
        if canonical is None:
            raise CampaignSelectionError(
                f"recipe {recipe} lacks canonical seed 424242"
            )
        receipt = validate_eligibility(canonical, receipts)
        if receipt is None:
            raise CampaignSelectionError(
                f"recipe {recipe} lacks promotion eligibility"
            )
        used_receipts.append(receipt)
    aggregates = [aggregate_recipe(items) for items in grouped.values()]
    receipt_by_recipe = {receipt["recipe"]: receipt for receipt in used_receipts}
    for aggregate in aggregates:
        receipt = receipt_by_recipe[aggregate["recipe"]]
        baseline = receipt["baseline_metrics"]
        thresholds = receipt["thresholds"]
        confirmation_checks = {
            "ex_noninferior": aggregate["item_clustered_ex"]
            >= baseline["ex"] - thresholds["ex_noninferiority_margin"],
            "valid_sql_noninferior": aggregate["valid_sql_rate"]
            >= baseline["valid_sql_rate"]
            - thresholds["valid_sql_noninferiority_margin"],
            "tier3_materially_better": aggregate["ex_by_tier"].get("3", 0.0)
            >= baseline["tier3_ex"]
            + thresholds["minimum_tier3_absolute_improvement"],
            "wrong_table_or_join_within_ceiling": aggregate[
                "wrong_table_or_join_rate"
            ]
            <= receipt["wrong_table_or_join_ceiling"],
        }
        aggregate["confirmation_eligibility"] = confirmation_checks
        if not all(confirmation_checks.values()):
            raise CampaignSelectionError(
                f"recipe {aggregate['recipe']} failed confirmation eligibility"
            )
    winner = max(
        aggregates,
        key=lambda item: (
            item["item_clustered_ex"],
            item["valid_sql_rate"],
            item["worst_tier_ex"],
            -item["p95_microseconds"],
            -item["trainable_parameter_count"],
            item["recipe"],
        ),
    )
    inputs = []
    for manifest in sorted(
        (item for values in grouped.values() for item in values),
        key=lambda item: item["run_id"],
    ):
        canonical = {
            key: value for key, value in manifest.items() if key != "_manifest_path"
        }
        source = manifest.get("_manifest_path")
        inputs.append(
            {
                "run_id": manifest["run_id"],
                "manifest_path": source,
                "manifest_sha256": (
                    sha256_file(Path(source))
                    if source
                    else hashlib.sha256(
                        json.dumps(
                            canonical,
                            sort_keys=True,
                            separators=(",", ":"),
                        ).encode()
                    ).hexdigest()
                ),
            }
        )
    return {
        "schema_version": CAMPAIGN_SELECTION_SCHEMA_VERSION,
        "analysis": CAMPAIGN_SELECTION_ANALYSIS,
        "selection_dataset": "gold_v1.jsonl",
        "confirmation_seeds": list(CONFIRMATION_SEEDS),
        "selection_order": [
            "promotion_eligibility_required",
            "item_clustered_ex_desc",
            "valid_sql_rate_desc",
            "worst_tier_ex_desc",
            "p95_latency_asc",
            "trainable_parameter_count_asc",
            "recipe_lexical_desc",
        ],
        "winner": winner,
        "recipes": sorted(aggregates, key=lambda x: x["recipe"]),
        "inputs": inputs,
        "eligibility": [
            {
                "candidate_run_id": receipt["candidate_run_id"],
                "path": receipt.get("_eligibility_path"),
                "sha256": (
                    sha256_file(Path(receipt["_eligibility_path"]))
                    if receipt.get("_eligibility_path")
                    else hashlib.sha256(
                        json.dumps(
                            {
                                key: value
                                for key, value in receipt.items()
                                if key != "_eligibility_path"
                            },
                            sort_keys=True,
                            separators=(",", ":"),
                        ).encode()
                    ).hexdigest()
                ),
            }
            for receipt in sorted(
                used_receipts, key=lambda item: item["candidate_run_id"]
            )
        ],
    }
