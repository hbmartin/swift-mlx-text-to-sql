"""Resume W&B synchronization for an immutable local experiment run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.file_integrity import regular_files
from eval.run_artifacts import REPO_ROOT, input_hash, sha256_file, write_json
from eval.wandb_evidence import (
    WandbEvidenceError,
    synchronize_manifest,
    validate_wandb_receipt,
)
from tools.run_experiment import finalize_synchronized_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--training-run", type=Path, required=True)
    parser.add_argument(
        "--promotion-eligibility",
        action="append",
        type=Path,
        help="passing reliability-v3 eligibility receipt used for promotion",
    )
    parser.add_argument(
        "--final-evaluation",
        action="append",
        type=Path,
        help="completed final evaluation run to attach as non-selection evidence",
    )
    parser.add_argument(
        "--publication",
        type=Path,
        help="fresh-verified Hugging Face publication record for the fused reference",
    )
    parser.add_argument(
        "--policy-calibration",
        action="append",
        type=Path,
        help="schema-v3 bounded-policy calibration evidence file or directory",
    )
    parser.add_argument(
        "--parity-evidence",
        action="append",
        type=Path,
        help="Swift/Python parity evidence file or directory",
    )
    parser.add_argument(
        "--release-inspection",
        action="append",
        type=Path,
        help="Release bundle inspection evidence file or directory",
    )
    parser.add_argument(
        "--device-evidence",
        action="append",
        type=Path,
        help="physical-device timing/thermal evidence file or directory",
    )
    parser.add_argument(
        "--headline-metrics",
        type=Path,
        help="JSON object of final headline metrics to mirror onto the winning run",
    )
    return parser.parse_args()


def verify_receipt(receipt: dict[str, Any]) -> None:
    validate_wandb_receipt(receipt)


def attach_selection_evidence(
    manifest_path: Path, promotion_eligibility: list[Path]
) -> None:
    if not promotion_eligibility:
        return
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("experiment", {}).get("stage") != "screening":
        raise WandbEvidenceError(
            "promotion eligibility attaches to the screening run it evaluated"
        )
    files = []
    for path in promotion_eligibility:
        absolute = path.absolute()
        input_hash(absolute)
        receipt = json.loads(absolute.read_text())
        if (
            receipt.get("analysis")
            != "reliability-v3-promotion-eligibility"
            or receipt.get("schema_version") != 1
            or receipt.get("pass") is not True
            or receipt.get("candidate_run_id") != manifest["run_id"]
            or receipt.get("selected_checkpoint_sha256")
            != manifest.get("checkpoint_evaluation", {})
            .get("selected", {})
            .get("checkpoint_sha256")
        ):
            raise WandbEvidenceError(
                "promotion eligibility is incomplete or belongs to another run"
            )
        files.append(str(absolute))
    manifest["selection_evidence"] = {
        "promotion-eligibility": {
            "selection_use": "required",
            "artifact_type": "evaluation",
            "files": sorted(set(files)),
        }
    }
    manifest["status"] = "local_complete"
    write_json(manifest_path, manifest)


def attach_post_selection_evidence(
    manifest_path: Path,
    *,
    final_evaluations: list[Path],
    publication_path: Path | None,
    policy_calibrations: list[Path] | None = None,
    parity_evidence: list[Path] | None = None,
    release_inspections: list[Path] | None = None,
    device_evidence: list[Path] | None = None,
    headline_metrics_path: Path | None = None,
) -> None:
    categories = {
        "policy-calibration": (policy_calibrations or [], "evaluation"),
        "swift-python-parity": (parity_evidence or [], "evaluation"),
        "release-bundle-inspection": (release_inspections or [], "evidence"),
        "physical-device-evidence": (device_evidence or [], "evaluation"),
    }
    if (
        not final_evaluations
        and publication_path is None
        and not any(values for values, _ in categories.values())
        and headline_metrics_path is None
    ):
        return
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("experiment", {}).get("stage") != "final":
        raise WandbEvidenceError(
            "final evaluation/publication evidence can only attach to a final run"
        )
    files: list[str] = []
    for directory in final_evaluations:
        directory = directory.resolve()
        evaluation_manifest = json.loads((directory / "manifest.json").read_text())
        summary = json.loads((directory / "summary.json").read_text())
        if evaluation_manifest.get("status") != "complete":
            raise WandbEvidenceError(f"final evaluation is incomplete: {directory}")
        if summary.get("gold") != "gold_v2.jsonl":
            raise WandbEvidenceError(
                f"post-selection evaluation is not gold_v2: {directory}"
            )
        files.extend(
            str(path.resolve())
            for path in (
                directory / "manifest.json",
                directory / "summary.json",
                directory / "items.jsonl",
            )
            if path.is_file()
        )
    if files:
        manifest["final_evaluation"] = {
            "selection_use": "forbidden",
            "files": sorted(set(files)),
        }
        manifest["corpus"]["gold_v2_held_out"] = input_hash(
            REPO_ROOT / "eval" / "gold" / "gold_v2.jsonl"
        )
    post_selection: dict[str, Any] = dict(
        manifest.get("post_selection_evidence", {})
    )
    for category, (values, artifact_type) in categories.items():
        category_files: list[str] = []
        for value in values:
            absolute = value.absolute()
            if absolute.is_dir():
                category_files.extend(
                    str(path) for path in regular_files(absolute)
                )
            elif absolute.is_file():
                # Hashing through input_hash also rejects symlinks via the
                # shared no-follow primitive before this enters the receipt.
                input_hash(absolute)
                category_files.append(str(absolute))
            else:
                raise WandbEvidenceError(f"evidence path does not exist: {absolute}")
        if category_files:
            post_selection[category] = {
                "selection_use": "forbidden",
                "artifact_type": artifact_type,
                "files": sorted(set(category_files)),
            }
    if post_selection:
        manifest["post_selection_evidence"] = post_selection

    if headline_metrics_path is not None:
        headline_metrics_path = headline_metrics_path.absolute()
        input_hash(headline_metrics_path)
        metrics = json.loads(headline_metrics_path.read_text())
        if not isinstance(metrics, dict) or not metrics:
            raise WandbEvidenceError("headline metrics must be a non-empty JSON object")
        invalid = [
            name
            for name, value in metrics.items()
            if not isinstance(name, str)
            or not isinstance(value, (int, float, bool))
            or isinstance(value, float) and (value != value or abs(value) == float("inf"))
        ]
        if invalid:
            raise WandbEvidenceError(f"headline metrics contain invalid values: {invalid}")
        manifest["headline_metrics"] = metrics
        post_selection["headline-metrics"] = {
            "selection_use": "forbidden",
            "artifact_type": "evaluation",
            "files": [str(headline_metrics_path)],
        }
        manifest["post_selection_evidence"] = post_selection
    if publication_path is not None:
        publication = json.loads(publication_path.resolve().read_text())
        if (
            publication.get("training_run_id") != manifest["run_id"]
            or not publication.get("fresh_download_verified")
        ):
            raise WandbEvidenceError(
                "publication is not a fresh-verified output of this training run"
            )
        fused = manifest.get("fused_reference")
        if not fused:
            raise WandbEvidenceError("final run has no fused model reference")
        published_value = publication.get("published_snapshot")
        if not published_value:
            raise WandbEvidenceError(
                "publication has no distinct verified published snapshot"
            )
        published = REPO_ROOT / published_value
        lock_path = published / ".creg-artifact.json"
        if not lock_path.is_file():
            raise WandbEvidenceError(
                f"published artifact lock is missing: {lock_path}"
            )
        lock = json.loads(lock_path.read_text())
        if (
            lock.get("repository") != publication["repository"]
            or lock.get("revision") != publication["revision"]
            or lock.get("directory_sha256") != publication["model_tree_sha256"]
        ):
            raise WandbEvidenceError(
                "publication record and published artifact lock disagree"
            )
        fused["repository"] = publication["repository"]
        fused["revision"] = publication["revision"]
        fused["publication_path"] = str(publication_path.resolve())
        fused["lock_path"] = str(lock_path.resolve())
        fused["directory_sha256"] = lock["directory_sha256"]
        fused["lock_sha256"] = sha256_file(lock_path)
    manifest["status"] = "local_complete"
    write_json(manifest_path, manifest)


def main() -> None:
    args = parse_args()
    manifest_path = args.training_run.resolve() / "manifest.json"
    attach_selection_evidence(
        manifest_path, args.promotion_eligibility or []
    )
    attach_post_selection_evidence(
        manifest_path,
        final_evaluations=args.final_evaluation or [],
        publication_path=args.publication,
        policy_calibrations=args.policy_calibration or [],
        parity_evidence=args.parity_evidence or [],
        release_inspections=args.release_inspection or [],
        device_evidence=args.device_evidence or [],
        headline_metrics_path=args.headline_metrics,
    )
    receipt = synchronize_manifest(manifest_path)
    verify_receipt(receipt)
    manifest = json.loads(manifest_path.read_text())
    if (
        manifest.get("experiment", {}).get("stage") == "screening"
        or manifest.get("fused_reference")
    ):
        manifest = finalize_synchronized_manifest(manifest_path)
    print(
        json.dumps(
            {
                "status": manifest["status"],
                "run_id": manifest["run_id"],
                "wandb": receipt,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
