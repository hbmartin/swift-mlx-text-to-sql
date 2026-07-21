"""Resume W&B synchronization for an immutable local experiment run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, input_hash, sha256_file, write_json
from eval.wandb_evidence import WandbEvidenceError, synchronize_manifest
from tools.run_experiment import finalize_synchronized_manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--training-run", type=Path, required=True)
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
    return parser.parse_args()


def verify_receipt(receipt: dict[str, Any]) -> None:
    if receipt.get("status") != "complete":
        raise WandbEvidenceError("W&B receipt is incomplete")
    required = ("entity", "project", "run_id", "url", "canonical_evidence_sha256")
    missing = [name for name in required if not receipt.get(name)]
    if missing:
        raise WandbEvidenceError(f"W&B receipt is missing {missing}")
    artifacts = receipt.get("artifacts", [])
    if not artifacts:
        raise WandbEvidenceError("W&B receipt has no artifact versions")
    for artifact in artifacts:
        absent = [
            name
            for name in ("name", "version", "digest", "type")
            if not artifact.get(name)
        ]
        if absent:
            raise WandbEvidenceError(
                f"artifact receipt {artifact.get('name')} is missing {absent}"
            )
        for file in artifact.get("files", []):
            if not file.get("path") or not file.get("sha256"):
                raise WandbEvidenceError("artifact file receipt lacks repository SHA-256")


def attach_post_selection_evidence(
    manifest_path: Path,
    *,
    final_evaluations: list[Path],
    publication_path: Path | None,
) -> None:
    if not final_evaluations and publication_path is None:
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
        fused["repository"] = publication["repository"]
        fused["revision"] = publication["revision"]
        fused["publication_path"] = str(publication_path.resolve())
        lock_path = Path(fused["lock_path"])
        lock = json.loads(lock_path.read_text())
        fused["directory_sha256"] = lock["directory_sha256"]
        fused["lock_sha256"] = sha256_file(lock_path)
    manifest["status"] = "local_complete"
    write_json(manifest_path, manifest)


def main() -> None:
    args = parse_args()
    manifest_path = args.training_run.resolve() / "manifest.json"
    attach_post_selection_evidence(
        manifest_path,
        final_evaluations=args.final_evaluation or [],
        publication_path=args.publication,
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
