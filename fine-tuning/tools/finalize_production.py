"""Write production configuration only after every blocking evidence gate.

This is the sole supported transition from `selection_pending` to `verified`.
It validates the four-artifact selection, N=3 calibration, both public
fine-tune snapshots, and full-gold Python/Swift parity before editing the
versioned model manifest.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, sha256_file, write_json
from eval.selection import SelectionError, load_run
from tools.fetch_model import load_manifest

MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production-analysis", type=Path, required=True)
    parser.add_argument("--consistency-analysis", type=Path, required=True)
    parser.add_argument("--parity-analysis", type=Path, required=True)
    parser.add_argument(
        "--publication",
        type=Path,
        action="append",
        required=True,
        help="fresh-verified publication.json (exactly two)",
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


def main() -> None:
    args = parse_args()
    if len(args.publication) != 2:
        raise SystemExit("--publication must be supplied exactly twice")

    production_path = args.production_analysis.resolve()
    consistency_path = args.consistency_analysis.resolve()
    parity_path = args.parity_analysis.resolve()
    production = read_json(production_path)
    consistency = read_json(consistency_path)
    parity = read_json(parity_path)

    if production.get("analysis") != "production-artifact-selection":
        raise SelectionError("invalid production-selection analysis")
    selected = production["selected"]
    if selected.get("seeds") != [0, 1, 2, 3, 4]:
        raise SelectionError("production selection is not based on five seeds")
    if selected.get("n_items") != 200:
        raise SelectionError("production selection is not full gold_v2")

    if consistency.get("analysis") != "n3-always-vote-calibration":
        raise SelectionError("invalid consistency analysis")
    voting = consistency["selected"]
    if (
        voting.get("model_key") != selected.get("model_key")
        or voting.get("gcd") != selected.get("gcd")
        or voting.get("candidate_count") != 3
        or voting.get("always_vote") is not True
        or voting.get("trial_seeds") != [0, 1, 2, 3, 4]
        or voting.get("n_trials") != 1_000
    ):
        raise SelectionError(
            "consistency calibration does not match the production winner"
        )

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
    python_run = load_run(python_run_path)
    python_summary = python_run.summary
    if (
        python_summary.get("model_key") != selected.get("model_key")
        or python_summary.get("gcd") != selected.get("gcd")
        or float(python_summary.get("temperature")) != float(
            selected.get("temperature")
        )
        or python_summary.get("n") != 200
    ):
        raise SelectionError(
            "parity Python run does not match the selected production configuration"
        )

    manifest = load_manifest(MODEL_MANIFEST)
    if (
        manifest.get("production") is not None
        or manifest.get("production_status") != "selection_pending"
    ):
        raise SelectionError("model manifest is not awaiting production selection")
    models = {model["key"]: model for model in manifest["models"]}
    model = models.get(selected["model_key"])
    if model is None:
        raise SelectionError("selected production model is not in the manifest")

    publications = [read_json(path.resolve()) for path in args.publication]
    if any(
        item.get("public") is not True
        or item.get("fresh_download_verified") is not True
        for item in publications
    ):
        raise SelectionError("both publication records must be fresh verified")
    publication_identities = {
        (item["repository"], item["revision"]) for item in publications
    }
    derived = [item for item in models.values() if item.get("derived")]
    if (
        len(derived) != 2
        or any(
            item.get("publication_status") != "public-verified"
            or (item.get("repository"), item.get("revision"))
            not in publication_identities
            for item in derived
        )
    ):
        raise SelectionError(
            "manifest does not contain exactly two fresh-verified public fine-tunes"
        )

    manifest["production"] = {
        "model_key": selected["model_key"],
        "gcd": selected["gcd"],
        "temperature": selected["temperature"],
        "top_p": 1.0,
        "top_k": 0,
        "max_tokens": 512,
        "voting": {
            "candidate_count": 3,
            "sample_temperature": voting["sample_temperature"],
            "always_vote": True,
        },
        "evidence": {
            "production_selection": evidence(production_path),
            "consistency_calibration": evidence(consistency_path),
            "full_gold_parity": evidence(parity_path),
            "publications": [
                evidence(path.resolve()) for path in args.publication
            ],
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
