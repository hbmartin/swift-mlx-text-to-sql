"""Write production configuration only after every blocking evidence gate.

This is the sole supported transition from `selection_pending` to `verified`.
It validates the gold-v1 campaign winner, its locked gold-v2 release gate,
permanent binding regressions, bounded three-generation calibration, published
snapshot evidence, and full-gold Python/Swift parity before editing the
versioned model manifest.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.campaign import (
    CAMPAIGN_SELECTION_ANALYSIS,
    CAMPAIGN_SELECTION_SCHEMA_VERSION,
    CONFIRMATION_SEEDS,
    LOCKED_PRODUCTION_GCD,
    LOCKED_PRODUCTION_TEMPERATURE,
    MINIMUM_PRODUCTION_EX,
)
from eval.run_artifacts import REPO_ROOT, sha256_file, write_json
from eval.selection import SelectionError, load_run
from tools.fetch_model import load_manifest

MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign-winner", type=Path, required=True)
    parser.add_argument("--final-evaluation-analysis", type=Path, required=True)
    parser.add_argument("--binding-analysis", type=Path, required=True)
    parser.add_argument("--consistency-analysis", type=Path, required=True)
    parser.add_argument("--parity-analysis", type=Path, required=True)
    parser.add_argument(
        "--publication",
        type=Path,
        action="append",
        required=True,
        help="fresh-verified publication.json (one or more)",
    )
    return parser.parse_args()


def read_json(path: Path) -> dict[str, Any]:
    decoded = json.loads(path.read_text())
    if not isinstance(decoded, dict):
        raise SelectionError(f"expected a JSON object: {path}")
    return decoded


def evidence(path: Path) -> dict[str, str]:
    resolved = path.resolve()
    try:
        display = resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        raise SelectionError(
            f"production evidence must live inside the repository: {resolved}"
        ) from None
    return {"path": display, "sha256": sha256_file(resolved)}


def validate_publication_arguments(paths: list[Path]) -> list[Path]:
    if not paths:
        raise SelectionError("--publication must be supplied at least once")
    if len(set(paths)) != len(paths):
        raise SelectionError("--publication values must be distinct")
    return paths


def validate_binding_analysis(
    binding: dict[str, Any], selected: dict[str, Any]
) -> None:
    if (
        binding.get("analysis") != "binding-regression-gate"
        or binding.get("schema_version") != 1
        or binding.get("pass") is not True
        or binding.get("seeds") != [0, 1, 2, 3, 4]
        or binding.get("item_count") != 15
        or binding.get("checks") != 75
        or binding.get("model_key") != selected.get("model_key")
        or binding.get("gcd") != selected.get("gcd")
        or float(binding.get("temperature", -1))
        != float(selected.get("temperature", -2))
    ):
        raise SelectionError(
            "binding regression gate does not match the production winner"
        )


def validate_campaign_winner(campaign: dict[str, Any]) -> dict[str, Any]:
    if (
        campaign.get("schema_version") != CAMPAIGN_SELECTION_SCHEMA_VERSION
        or campaign.get("analysis") != CAMPAIGN_SELECTION_ANALYSIS
        or campaign.get("selection_dataset") != "gold_v1.jsonl"
        or campaign.get("confirmation_seeds") != list(CONFIRMATION_SEEDS)
    ):
        raise SelectionError("invalid gold-v1 campaign winner")
    winner = campaign.get("winner", {})
    if (
        not winner.get("artifact_model_key")
        or winner.get("gcd") != LOCKED_PRODUCTION_GCD
        or float(winner.get("temperature", -1)) != LOCKED_PRODUCTION_TEMPERATURE
    ):
        raise SelectionError("campaign winner lacks a locked artifact identity")
    return winner


def validate_final_evaluation(
    evaluation: dict[str, Any], winner: dict[str, Any]
) -> dict[str, Any]:
    if (
        evaluation.get("schema_version") != 1
        or evaluation.get("analysis") != "final-gold-v2-evaluation"
        or evaluation.get("selection_permitted") is not False
        or evaluation.get("pass") is not True
    ):
        raise SelectionError("invalid locked-winner gold-v2 evaluation")
    selected = evaluation.get("result", {})
    receipt = evaluation.get("campaign_winner", {})
    if (
        receipt.get("artifact_model_key") != winner.get("artifact_model_key")
        or receipt.get("recipe") != winner.get("recipe")
        or selected.get("model_key") != winner.get("artifact_model_key")
        or selected.get("gcd") != winner.get("gcd")
        or float(selected.get("temperature", -1))
        != float(winner.get("temperature", -2))
        or selected.get("seeds") != [0, 1, 2, 3, 4]
        or selected.get("n_items") != 200
    ):
        raise SelectionError(
            "final evaluation does not match the gold-v1 campaign winner"
        )
    if float(selected.get("ex", -1)) < MINIMUM_PRODUCTION_EX:
        raise SelectionError(
            "final evaluation does not meet the 66.8% EX release floor"
        )
    return selected


def validate_consistency_analysis(
    consistency: dict[str, Any], selected: dict[str, Any]
) -> dict[str, Any]:
    if (
        consistency.get("analysis") != "bounded-three-generation-calibration"
        or consistency.get("schema_version") != 3
        or consistency.get("policy_version") != "bounded-three-generation-v1"
        or consistency.get("release_gate_passed") is not True
    ):
        raise SelectionError("invalid consistency analysis")
    voting = consistency["selected"]
    if (
        voting.get("model_key") != selected.get("model_key")
        or voting.get("gcd") != selected.get("gcd")
        or voting.get("candidate_count") != 3
        or voting.get("bounded_policy") is not True
        or voting.get("always_vote") is not False
        or float(voting.get("sample_temperature", -1)) != 0.7
        or voting.get("trial_seeds") != [0, 1, 2, 3, 4]
        or voting.get("n_trials") != 1_000
    ):
        raise SelectionError(
            "consistency calibration does not match the production winner"
        )
    return voting


def validate_parity_analysis(parity: dict[str, Any], selected: dict[str, Any]) -> None:
    gate = parity.get("gate", {})
    if (
        parity.get("analysis") != "python-swift-full-gold-parity"
        or parity.get("n") != 200
        or gate.get("pass") is not True
    ):
        raise SelectionError("blocking full-gold parity gate did not pass")
    python_run_path = Path(parity["inputs"]["python_run"]["path"])
    if not python_run_path.is_absolute():
        python_run_path = REPO_ROOT / python_run_path
    python_summary = load_run(python_run_path).summary
    if (
        python_summary.get("model_key") != selected.get("model_key")
        or python_summary.get("gcd") != selected.get("gcd")
        or float(python_summary.get("temperature"))
        != float(selected.get("temperature"))
        or python_summary.get("n") != 200
    ):
        raise SelectionError(
            "parity Python run does not match the selected production configuration"
        )


def main() -> None:
    args = parse_args()
    publication_paths = validate_publication_arguments(args.publication)

    campaign_path = args.campaign_winner.resolve()
    final_evaluation_path = args.final_evaluation_analysis.resolve()
    binding_path = args.binding_analysis.resolve()
    consistency_path = args.consistency_analysis.resolve()
    parity_path = args.parity_analysis.resolve()
    campaign = read_json(campaign_path)
    final_evaluation = read_json(final_evaluation_path)
    binding = read_json(binding_path)
    consistency = read_json(consistency_path)
    parity = read_json(parity_path)

    winner = validate_campaign_winner(campaign)
    selected = validate_final_evaluation(final_evaluation, winner)

    validate_binding_analysis(binding, selected)
    voting = validate_consistency_analysis(consistency, selected)
    validate_parity_analysis(parity, selected)

    manifest = load_manifest(MODEL_MANIFEST)
    existing_production = manifest.get("production")
    if manifest.get("production_status") not in {"selection_pending", "verified"}:
        raise SelectionError("model manifest has an unsupported production state")
    if (
        existing_production is not None
        and existing_production.get("policy_version") == "bounded-three-generation-v1"
    ):
        raise SelectionError("bounded-policy production is already finalized")
    models = {model["key"]: model for model in manifest["models"]}
    model = models.get(selected["model_key"])
    if model is None:
        raise SelectionError("selected production model is not in the manifest")

    publications = [read_json(path.resolve()) for path in publication_paths]
    if any(
        item.get("public") is not True
        or item.get("fresh_download_verified") is not True
        for item in publications
    ):
        raise SelectionError("all publication records must be fresh verified")
    publication_identities = {
        (item["repository"], item["revision"]) for item in publications
    }
    if len(publication_identities) != len(publications):
        raise SelectionError("publication records must name distinct revisions")
    derived = [
        item
        for item in models.values()
        if item.get("derived")
        and item.get("publication_status") == "public-verified"
        and (item.get("repository"), item.get("revision")) in publication_identities
    ]
    if len(derived) != len(publication_identities) or model not in derived:
        raise SelectionError(
            "manifest does not contain every supplied fresh-verified public fine-tune"
        )
    for item in derived:
        if item.get("experiment_authority") != "wandb":
            continue
        receipt = item.get("training_provenance", {}).get("wandb", {})
        if receipt.get("status") != "complete":
            raise SelectionError(
                f"{item['key']} is missing complete W&B experiment evidence"
            )

    manifest["production"] = {
        "model_key": selected["model_key"],
        "gcd": selected["gcd"],
        "temperature": selected["temperature"],
        "top_p": 1.0,
        "top_k": 0,
        "max_tokens": 512,
        "policy_version": "bounded-three-generation-v1",
        "voting": {
            "candidate_count": 3,
            "sample_temperature": voting["sample_temperature"],
            "always_vote": False,
        },
        "evidence": {
            "campaign_winner": evidence(campaign_path),
            "final_gold_v2_evaluation": evidence(final_evaluation_path),
            "binding_regressions": evidence(binding_path),
            "consistency_calibration": evidence(consistency_path),
            "full_gold_parity": evidence(parity_path),
            "publications": [evidence(path.resolve()) for path in publication_paths],
        },
    }
    manifest["production_status"] = "verified"
    write_json(MODEL_MANIFEST, manifest)
    load_manifest(MODEL_MANIFEST)
    print(
        json.dumps(
            {
                "production_status": "verified",
                "model_key": selected["model_key"],
                "gcd": selected["gcd"],
                "temperature": selected["temperature"],
                "sample_temperature": voting["sample_temperature"],
                "manifest_sha256": sha256_file(MODEL_MANIFEST),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except SelectionError as error:
        raise SystemExit(f"production finalization failed: {error}") from error
