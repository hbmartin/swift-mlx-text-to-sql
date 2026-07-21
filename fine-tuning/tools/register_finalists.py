"""Register two trained finalists in the versioned model manifest.

The local phase adds hash-addressed, explicitly unpublished artifacts so they
can be evaluated without inventing a Hub revision. The published phase replaces
those declarations with the public commit revisions and final verified file
inventories produced by publish_finalists.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import REPO_ROOT, sha256_file, write_json
from tools.fetch_model import (
    LOCK_FILE,
    load_manifest,
    validate_artifact_declaration,
    verify_required_files,
)

MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["local", "published"])
    parser.add_argument(
        "--training-run",
        action="append",
        type=Path,
        required=True,
        help="completed immutable training-run directory (exactly two)",
    )
    parser.add_argument(
        "--publication",
        action="append",
        type=Path,
        help=(
            "fresh-verified publication.json (exactly two for the published "
            "phase; forbidden for local)"
        ),
    )
    return parser.parse_args()


def completed_training(path: Path) -> dict[str, Any]:
    manifest = json.loads((path / "manifest.json").read_text())
    if manifest.get("status") != "complete":
        raise RuntimeError(f"training run is not complete: {path}")
    return manifest


def local_entry(
    training: dict[str, Any],
    current_base: dict[str, Any],
) -> dict[str, Any]:
    # License review may become stricter while a long-running training job is
    # in flight. Artifact registration uses the current pinned base
    # declaration without rewriting the immutable training record.
    entry = {
        **training["candidate_manifest_entry"],
        "license": current_base["license"],
    }
    validate_artifact_declaration(entry)
    fused = Path(training["outputs"]["fused"])
    verify_required_files(fused, entry)
    configuration = json.loads((fused / "config.json").read_text())
    quantization = configuration.get("quantization", {})
    if (
        quantization.get("bits") != 4
        or quantization.get("group_size") != 64
        or quantization.get("mode", "affine") != "affine"
    ):
        raise RuntimeError(
            f"{entry['key']}: fused output did not preserve MLX 4-bit "
            "group-64 affine quantization"
        )
    return entry


def published_entry(
    existing: dict[str, Any],
    training: dict[str, Any],
    publication_path: Path,
) -> dict[str, Any]:
    if not publication_path.is_file():
        raise RuntimeError(f"publication record is missing: {publication_path}")
    publication = json.loads(publication_path.read_text())
    if not publication.get("fresh_download_verified"):
        raise RuntimeError(
            f"publication was not fresh-download verified: {publication_path}"
        )
    if publication.get("training_run_id") != training["run_id"]:
        raise RuntimeError(
            f"publication does not belong to {training['run_id']}: "
            f"{publication_path}"
        )
    fused = Path(training["outputs"]["fused"])
    lock = json.loads((fused / LOCK_FILE).read_text())
    if (
        lock.get("repository") != publication["repository"]
        or lock.get("revision") != publication["revision"]
    ):
        raise RuntimeError(
            f"publication and fused lock disagree: {publication_path}"
        )
    entry = {
        **existing,
        "repository": publication["repository"],
        "revision": publication["revision"],
        "publication_status": "public-verified",
        "snapshot_directory_sha256": lock["directory_sha256"],
        "required_files": lock["all_files"],
        "training_provenance": lock["training_provenance"],
    }
    validate_artifact_declaration(entry)
    return entry


def main() -> None:
    args = parse_args()
    if len(args.training_run) != 2 or len(set(args.training_run)) != 2:
        raise SystemExit("--training-run must be supplied exactly twice")
    paths = [path.resolve() for path in args.training_run]
    training_runs = [completed_training(path) for path in paths]
    manifest = load_manifest(MODEL_MANIFEST)
    models = manifest["models"]
    by_key = {model["key"]: model for model in models}
    before = sha256_file(MODEL_MANIFEST)

    if args.phase == "local":
        if args.publication:
            raise SystemExit("local registration does not accept --publication")
        entries = [
            local_entry(training, by_key[training["base"]["key"]])
            for training in training_runs
        ]
        duplicates = set(entry["key"] for entry in entries) & set(by_key)
        if duplicates:
            raise RuntimeError(
                f"refusing to overwrite existing manifest entries: {sorted(duplicates)}"
            )
        models.extend(entries)
    else:
        if len(args.publication or []) != 2:
            raise SystemExit(
                "published registration requires exactly two --publication values"
            )
        publication_by_training_run = {}
        for path in args.publication:
            resolved = path.resolve()
            record = json.loads(resolved.read_text())
            publication_by_training_run[record["training_run_id"]] = resolved
        if len(publication_by_training_run) != 2:
            raise RuntimeError("publication records must name distinct training runs")
        for run_path, training in zip(paths, training_runs, strict=True):
            key = training["candidate_manifest_entry"]["key"]
            existing = by_key.get(key)
            if existing is None or existing.get("publication_status") != "local-unpublished":
                raise RuntimeError(
                    f"{key}: expected an existing local-unpublished declaration"
                )
            publication_path = publication_by_training_run.get(
                training["run_id"]
            )
            if publication_path is None:
                raise RuntimeError(
                    f"missing publication for {training['run_id']}"
                )
            replacement = published_entry(
                existing, training, publication_path
            )
            models[models.index(existing)] = replacement

    write_json(MODEL_MANIFEST, manifest)
    # Re-parse the persisted document before reporting success.
    load_manifest(MODEL_MANIFEST)
    print(
        json.dumps(
            {
                "phase": args.phase,
                "manifest": str(MODEL_MANIFEST),
                "before_sha256": before,
                "after_sha256": sha256_file(MODEL_MANIFEST),
                "registered_keys": [
                    training["candidate_manifest_entry"]["key"]
                    for training in training_runs
                ],
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
