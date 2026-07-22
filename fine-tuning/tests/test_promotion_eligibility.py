import json

import pytest

from eval.run_artifacts import write_json
from tools.analyze_promotion_eligibility import (
    PromotionEligibilityError,
    analyze,
)


def item(index, *, ex, error=None, bucket="correct"):
    return {
        "id": f"item-{index}",
        "tier": 3 if index >= 6 else 2,
        "ex": ex,
        "error": error,
        "bucket": bucket,
    }


def write_items(path, items):
    path.write_text("\n".join(json.dumps(value) for value in items) + "\n")


def fixture(tmp_path):
    database_set = "d" * 64
    baseline = tmp_path / "baseline"
    baseline.mkdir()
    baseline_items = [
        item(index, ex=index < 6, error="syntax" if index == 9 else None,
             bucket="wrong-table-or-join" if index == 8 else "correct")
        for index in range(10)
    ]
    candidate_items = [
        item(index, ex=index < 8, error="syntax" if index == 9 else None)
        for index in range(10)
    ]
    write_json(baseline / "manifest.json", {"status": "complete"})
    write_json(
        baseline / "summary.json",
        {
            "gold": "gold_v1.jsonl",
            "model_key": "ft-xiyansql-qwencoder-3b",
            "gcd": "on",
            "temperature": 0.0,
            "snapshot_count": 3,
            "database_set_sha256": database_set,
        },
    )
    write_items(baseline / "items.jsonl", baseline_items)

    evaluation = tmp_path / "candidate-items.jsonl"
    write_items(evaluation, candidate_items)
    candidate = tmp_path / "candidate.json"
    write_json(
        candidate,
        {
            "status": "complete",
            "run_id": "candidate-run",
            "experiment": {
                "model_key": "qwen25-coder-3b",
                "configuration_sha256": "c" * 64,
            },
            "checkpoint_evaluation": {
                "selected": {
                    "checkpoint_sha256": "e" * 64,
                    "items_path": str(evaluation),
                    "summary": {
                        "gold": "gold_v1.jsonl",
                        "gcd": "on",
                        "temperature": 0.0,
                        "snapshot_count": 3,
                        "database_set_sha256": database_set,
                    },
                }
            },
        },
    )
    binding = tmp_path / "binding.json"
    write_json(
        binding,
        {
            "schema_version": 1,
            "analysis": "binding-regression-gate",
            "pass": True,
            "item_count": 15,
            "seeds": [0, 1, 2, 3, 4],
            "checks": 75,
            "model_key": "qwen25-coder-3b",
            "gcd": "on",
            "temperature": 0.0,
            "evaluated_artifact": {
                "kind": "adapter-checkpoint",
                "sha256": "e" * 64,
            },
        },
    )
    return candidate, binding, baseline


def test_eligibility_uses_binding_and_matched_multi_snapshot_noninferiority(tmp_path):
    candidate, binding, baseline = fixture(tmp_path)
    result = analyze(candidate, binding, baseline)
    assert result["pass"] is True
    assert result["checks"] == {
        "binding_15_by_5": True,
        "ex_noninferior": True,
        "valid_sql_noninferior": True,
        "tier3_materially_better": True,
        "wrong_table_or_join_within_ceiling": True,
    }
    # 99% remains a full-policy release threshold, not a single-shot gate.
    assert result["candidate_metrics"]["valid_sql_rate"] == 0.9
    assert result["release_policy_valid_sql_rate"] == 0.99


def test_eligibility_refuses_a_failed_binding_receipt(tmp_path):
    candidate, binding, baseline = fixture(tmp_path)
    payload = json.loads(binding.read_text())
    payload["pass"] = False
    write_json(binding, payload)
    with pytest.raises(PromotionEligibilityError, match="binding receipt"):
        analyze(candidate, binding, baseline)


def test_eligibility_refuses_binding_evidence_from_another_checkpoint(tmp_path):
    candidate, binding, baseline = fixture(tmp_path)
    payload = json.loads(binding.read_text())
    payload["evaluated_artifact"]["sha256"] = "f" * 64
    write_json(binding, payload)
    with pytest.raises(PromotionEligibilityError, match="binding receipt"):
        analyze(candidate, binding, baseline)
