import copy
import json
from pathlib import Path

import pytest

from eval.run_artifacts import sha256_file
from eval.selection import Run, SelectionError
from tools import analyze_binding_regressions, finalize_production
from tools.finalize_production import (
    validate_binding_analysis,
    validate_campaign_winner,
    validate_consistency_analysis,
    validate_final_evaluation,
    validate_parity_analysis,
    validate_publication_arguments,
)


def fixture_rows() -> list[dict]:
    return [
        {
            "id": f"B-{index:02d}",
            "tier": 1,
            "tags": ["binding-regression"],
            "question": f"question {index}",
            "sql": f"SELECT {index}",
        }
        for index in range(15)
    ]


def install_fixture(monkeypatch, tmp_path: Path) -> tuple[Path, list[dict]]:
    regressions = tmp_path / "eval" / "gold" / "binding_regressions.jsonl"
    regressions.parent.mkdir(parents=True)
    rows = fixture_rows()
    regressions.write_text("".join(json.dumps(row) + "\n" for row in rows))
    monkeypatch.setattr(analyze_binding_regressions, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(analyze_binding_regressions, "REGRESSIONS", regressions)
    return regressions, rows


def make_run(
    directory: Path,
    seed: int,
    rows: list[dict],
    fixture_hash: str,
) -> Run:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "manifest.json").write_text("{}\n")
    return Run(
        directory=directory,
        manifest={
            "inputs": {"gold": {"sha256": fixture_hash}},
            "adapter": {"checkpoint": {"sha256": "a" * 64}},
        },
        summary={
            "model_key": "winner",
            "gcd": "on",
            "temperature": 0,
            "seed": seed,
        },
        items=tuple({"id": row["id"], "error": None, "ex": True} for row in rows),
    )


def test_binding_gate_requires_all_cases_to_pass_all_five_seeds(monkeypatch, tmp_path):
    regressions, rows = install_fixture(monkeypatch, tmp_path)
    fixture_hash = sha256_file(regressions)
    runs = {
        f"run-{seed}": make_run(tmp_path / f"run-{seed}", seed, rows, fixture_hash)
        for seed in range(5)
    }
    monkeypatch.setattr(
        analyze_binding_regressions,
        "load_run",
        lambda path: runs[path.name],
    )

    result = analyze_binding_regressions.analyze([tmp_path / name for name in runs])

    assert result["pass"] is True
    assert result["checks"] == 75
    assert result["evaluated_artifact"] == {
        "kind": "adapter-checkpoint",
        "sha256": "a" * 64,
    }
    assert result["failures"] == []
    assert result["regressions"]["sha256"] == fixture_hash


def test_binding_gate_rejects_a_missing_case(monkeypatch, tmp_path):
    regressions, rows = install_fixture(monkeypatch, tmp_path)
    fixture_hash = sha256_file(regressions)
    runs = {
        f"run-{seed}": make_run(tmp_path / f"run-{seed}", seed, rows[:-1], fixture_hash)
        for seed in range(5)
    }
    monkeypatch.setattr(
        analyze_binding_regressions,
        "load_run",
        lambda path: runs[path.name],
    )

    with pytest.raises(SelectionError, match="wrong binding regression input"):
        analyze_binding_regressions.analyze(
            [tmp_path / f"run-{seed}" for seed in range(5)]
        )


def test_binding_gate_records_any_failed_check(monkeypatch, tmp_path):
    regressions, rows = install_fixture(monkeypatch, tmp_path)
    fixture_hash = sha256_file(regressions)
    runs = [
        make_run(tmp_path / f"run-{seed}", seed, rows, fixture_hash)
        for seed in range(5)
    ]
    broken_items = [dict(item) for item in runs[3].items]
    broken_items[7]["error"] = "no such column"
    runs[3] = Run(
        directory=runs[3].directory,
        manifest=runs[3].manifest,
        summary=runs[3].summary,
        items=tuple(broken_items),
    )
    by_name = {run.directory.name: run for run in runs}
    monkeypatch.setattr(
        analyze_binding_regressions,
        "load_run",
        lambda path: by_name[path.name],
    )

    result = analyze_binding_regressions.analyze([run.directory for run in runs])

    assert result["pass"] is False
    assert result["failures"] == [
        {
            "run": "run-3",
            "id": "B-07",
            "error": "no such column",
            "ex": True,
        }
    ]


def test_binding_gate_rejects_mixed_checkpoint_evidence(monkeypatch, tmp_path):
    regressions, rows = install_fixture(monkeypatch, tmp_path)
    fixture_hash = sha256_file(regressions)
    runs = [
        make_run(tmp_path / f"run-{seed}", seed, rows, fixture_hash)
        for seed in range(5)
    ]
    changed_manifest = copy.deepcopy(runs[-1].manifest)
    changed_manifest["adapter"]["checkpoint"]["sha256"] = "b" * 64
    runs[-1] = Run(
        directory=runs[-1].directory,
        manifest=changed_manifest,
        summary=runs[-1].summary,
        items=runs[-1].items,
    )
    by_name = {run.directory.name: run for run in runs}
    monkeypatch.setattr(
        analyze_binding_regressions,
        "load_run",
        lambda path: by_name[path.name],
    )

    with pytest.raises(SelectionError, match="one identical artifact"):
        analyze_binding_regressions.analyze([run.directory for run in runs])


def test_production_finalization_requires_matching_binding_receipt():
    selected = {"model_key": "winner", "gcd": "on", "temperature": 0}
    binding = {
        "schema_version": 1,
        "analysis": "binding-regression-gate",
        "pass": True,
        "model_key": "winner",
        "gcd": "on",
        "temperature": 0,
        "seeds": [0, 1, 2, 3, 4],
        "item_count": 15,
        "checks": 75,
    }

    validate_binding_analysis(binding, selected)
    stale = copy.deepcopy(binding)
    stale["model_key"] = "old-model"
    with pytest.raises(SelectionError, match="does not match"):
        validate_binding_analysis(stale, selected)


def test_production_finalization_locks_gold_v2_to_gold_v1_winner(tmp_path):
    campaign = {
            "schema_version": 2,
            "analysis": "reliability-v3-campaign-selection",
        "selection_dataset": "gold_v1.jsonl",
        "confirmation_seeds": [424240, 424241, 424242],
        "winner": {
            "artifact_model_key": "winner",
            "recipe": "base:recipe",
            "gcd": "on",
            "temperature": 0,
        },
    }
    campaign_path = tmp_path / "campaign-winner.json"
    campaign_path.write_text(json.dumps(campaign))
    winner = validate_campaign_winner(campaign)
    analysis = {
        "schema_version": 1,
        "analysis": "final-gold-v2-evaluation",
        "selection_permitted": False,
        "pass": True,
        "inputs": {
            "campaign_winner": {"sha256": sha256_file(campaign_path)},
        },
        "campaign_winner": {
            "artifact_model_key": "winner",
            "recipe": "base:recipe",
        },
        "result": {
            "model_key": "winner",
            "gcd": "on",
            "temperature": 0,
            "seeds": [0, 1, 2, 3, 4],
            "n_items": 200,
            "ex": 0.668,
        },
    }

    assert validate_final_evaluation(analysis, winner, campaign_path)["ex"] == 0.668
    analysis["result"]["model_key"] = "gold-v2-challenger"
    with pytest.raises(SelectionError, match="does not match"):
        validate_final_evaluation(analysis, winner, campaign_path)
    analysis["result"]["model_key"] = "winner"
    analysis["result"]["ex"] = 0.6679
    with pytest.raises(SelectionError, match=r"66\.8% EX"):
        validate_final_evaluation(analysis, winner, campaign_path)
    analysis["result"]["ex"] = 0.668
    analysis["inputs"]["campaign_winner"]["sha256"] = "0" * 64
    with pytest.raises(SelectionError, match="does not match"):
        validate_final_evaluation(analysis, winner, campaign_path)


def test_production_finalization_validates_consistency_calibration():
    selected = {"model_key": "winner", "gcd": "on", "temperature": 0}
    voting = {
        "model_key": "winner",
        "gcd": "on",
        "candidate_count": 3,
        "bounded_policy": True,
        "always_vote": False,
        "sample_temperature": 0.7,
        "trial_seeds": [0, 1, 2, 3, 4],
        "n_trials": 1_000,
    }
    analysis = {
        "analysis": "bounded-three-generation-calibration",
        "schema_version": 3,
        "policy_version": "bounded-three-generation-v1",
        "release_gate_passed": True,
        "selected": voting,
    }

    assert validate_consistency_analysis(analysis, selected) == voting
    analysis["selected"]["candidate_count"] = 2
    with pytest.raises(SelectionError, match="does not match"):
        validate_consistency_analysis(analysis, selected)


def test_production_finalization_validates_full_gold_parity(monkeypatch, tmp_path):
    selected = {"model_key": "winner", "gcd": "on", "temperature": 0}
    python_run = make_run(tmp_path / "python-run", 0, fixture_rows(), "fixture")
    python_run.summary.update({"n": 200})
    monkeypatch.setattr(finalize_production, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(finalize_production, "load_run", lambda _: python_run)
    analysis = {
        "analysis": "python-swift-full-gold-parity",
        "n": 200,
        "gate": {"pass": True},
        "inputs": {"python_run": {"path": "python-run"}},
    }

    validate_parity_analysis(analysis, selected)
    python_run.summary["model_key"] = "stale"
    with pytest.raises(SelectionError, match="does not match"):
        validate_parity_analysis(analysis, selected)


@pytest.mark.parametrize("count", [1, 3])
def test_production_finalization_accepts_one_or_more_publications(tmp_path, count):
    paths = [tmp_path / f"publication-{index}.json" for index in range(count)]
    assert validate_publication_arguments(paths) == paths
