import json

from eval.campaign import promotion_plan, select_campaign_winner


def manifest(tmp_path, family, recipe, seed, ex, parameters):
    items_path = tmp_path / f"{family}-{recipe}-{seed}.jsonl"
    items = [
        {
            "id": f"item-{index}",
            "tier": 1 if index < 2 else 2,
            "ex": index / 4 < ex,
            "error": None,
            "elapsed_microseconds": 100 + index,
        }
        for index in range(4)
    ]
    items_path.write_text("\n".join(json.dumps(item) for item in items) + "\n")
    summary = {
        "gold": "gold_v1.jsonl",
        "ex": ex,
        "valid_sql_rate": 1.0,
        "ex_by_tier": {"1": ex, "2": ex},
        "p95_microseconds": 200,
    }
    return {
        "run_id": f"{family}-{recipe}-{seed}",
        "status": "complete",
        "experiment": {
            "model_key": family,
            "configuration_sha256": recipe,
            "stage": "screening" if seed == 424242 else "promoted",
            "seed": seed,
            **parameters,
        },
        "checkpoint_evaluation": {
            "selected": {
                "iteration": 100,
                "checkpoint_sha256": f"{seed:064x}"[-64:],
                "summary": summary,
                "items_path": str(items_path),
            }
        },
        "trainable_parameter_count": parameters["rank"] * 100,
    }


def parameters(rank=8):
    return {
        "fine_tune_type": "lora",
        "trainable_layers": "last-16",
        "rank": rank,
        "scale_ratio": 2.0,
        "dropout": 0.0,
        "learning_rate": 1e-4,
        "iterations": 600,
        "repair_fraction": 0.10,
    }


def eligibility(manifest):
    return {
        "schema_version": 1,
        "analysis": "reliability-v3-promotion-eligibility",
        "candidate_run_id": manifest["run_id"],
        "recipe": (
            f"{manifest['experiment']['model_key']}:"
            f"{manifest['experiment']['configuration_sha256']}"
        ),
        "model_key": manifest["experiment"]["model_key"],
        "selected_checkpoint_sha256": manifest["checkpoint_evaluation"]["selected"][
            "checkpoint_sha256"
        ],
        "baseline_metrics": {
            "ex": 0.0,
            "valid_sql_rate": 0.0,
            "tier3_ex": 0.0,
            "wrong_table_or_join_rate": 1.0,
        },
        "thresholds": {
            "ex_noninferiority_margin": 0.02,
            "valid_sql_noninferiority_margin": 0.0,
            "minimum_tier3_absolute_improvement": 0.0,
        },
        "wrong_table_or_join_ceiling": 1.0,
        "pass": True,
    }


def test_promotion_plan_reuses_four_screening_runs_and_adds_eight(tmp_path):
    screening = []
    for family in ("qwen25-coder-3b", "xiyansql-qwencoder-3b"):
        for index, ex in enumerate((0.9, 0.8, 0.7)):
            screening.append(
                manifest(
                    tmp_path,
                    family,
                    f"recipe-{index}",
                    424242,
                    ex,
                    parameters(rank=4 + index * 4),
                )
            )
    receipts = [eligibility(item) for item in screening]
    plan = promotion_plan(screening, receipts)
    assert plan["screening_runs"] == 4
    assert plan["promoted_seed_results"] == 12
    assert plan["additional_training_runs"] == 8


def test_winner_uses_clustered_development_metrics_and_canonical_seed(tmp_path):
    promoted = []
    recipes = [
        ("qwen25-coder-3b", "recipe-a", 1.0, 8),
        ("qwen25-coder-3b", "recipe-b", 0.75, 4),
        ("xiyansql-qwencoder-3b", "recipe-c", 0.5, 4),
        ("xiyansql-qwencoder-3b", "recipe-d", 0.25, 4),
    ]
    for family, recipe, ex, rank in recipes:
        for seed in (424240, 424241, 424242):
            promoted.append(
                manifest(
                    tmp_path,
                    family,
                    recipe,
                    seed,
                    ex,
                    parameters(rank=rank),
                )
            )
    receipts = [
        eligibility(item)
        for item in promoted
        if item["experiment"]["seed"] == 424242
    ]
    result = select_campaign_winner(promoted, receipts)
    assert result["analysis"] == "reliability-v3-campaign-selection"
    assert result["selection_dataset"] == "gold_v1.jsonl"
    assert result["confirmation_seeds"] == [424240, 424241, 424242]
    assert result["winner"]["recipe"] == "qwen25-coder-3b:recipe-a"
    assert result["winner"]["canonical_seed_run_id"].endswith("424242")
    assert result["winner"]["artifact_model_key"].startswith("ft-")
    assert len(result["inputs"]) == 12
    assert all(len(item["manifest_sha256"]) == 64 for item in result["inputs"])


def test_promotion_rejects_a_high_ex_recipe_without_binding_eligibility(tmp_path):
    screening = []
    for family in ("qwen25-coder-3b", "xiyansql-qwencoder-3b"):
        for index, ex in enumerate((1.0, 0.9, 0.8)):
            screening.append(
                manifest(
                    tmp_path,
                    family,
                    f"recipe-{index}",
                    424242,
                    ex,
                    parameters(rank=4 + index * 4),
                )
            )
    receipts = [
        eligibility(item)
        for item in screening
        if not item["run_id"].endswith("recipe-0-424242")
    ]
    plan = promotion_plan(screening, receipts)
    assert all(
        confirmation["configuration_sha256"] != "recipe-0"
        for confirmation in plan["confirmations"]
    )
