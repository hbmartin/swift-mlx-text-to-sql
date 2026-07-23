"""Verify that an app bundle contains the exact selected production snapshot."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from eval.run_artifacts import (
    REPO_ROOT,
    create_run_directory,
    sha256_file,
    write_json,
)
from tools.fetch_model import (
    directory_digest,
    directory_inventory,
    distribution_files,
    full_directory_inventory,
    load_manifest,
    notice_file,
)

DEFAULT_REPORTS = REPO_ROOT / "eval" / "build-verification"
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--configuration",
        choices=("Debug", "Release"),
        default="Release",
        help="build configuration recorded in the verification report",
    )
    parser.add_argument("--reports-dir", type=Path, default=DEFAULT_REPORTS)
    return parser.parse_args()


def expected_snapshot(
    artifact: dict[str, Any],
) -> tuple[list[dict[str, Any]], str]:
    conversion = artifact.get("conversion")
    if conversion is not None:
        return conversion["required_files"], conversion["directory_sha256"]
    return (
        artifact["required_files"],
        artifact["snapshot_directory_sha256"],
    )


def main() -> None:
    args = parse_args()
    app = args.app.resolve()
    bundled_manifest = app / "model-manifest.json"
    bundled_receipt = app / "production-model-receipt.json"
    model_directory = app / "SQLModel"
    if (
        not bundled_manifest.is_file()
        or not bundled_receipt.is_file()
        or not model_directory.is_dir()
    ):
        raise SystemExit(
            f"{args.configuration} bundle is missing model-manifest.json, "
            f"production-model-receipt.json, or SQLModel: {app}"
        )
    if bundled_manifest.read_bytes() != MODEL_MANIFEST.read_bytes():
        raise SystemExit("bundled model manifest is not byte-identical to source")

    manifest = load_manifest(bundled_manifest)
    production = manifest.get("production")
    if (
        production is None
        or manifest.get("production_status") != "verified"
        or production.get("policy_version") != "bounded-three-generation-v1"
    ):
        raise SystemExit(
            "bundled manifest has no verified bounded-policy production selection"
        )
    artifact = next(
        model
        for model in manifest["models"]
        if model["key"] == production["model_key"]
    )
    receipt = json.loads(bundled_receipt.read_text())
    receipt_identity = {
        "model_key": artifact["key"],
        "repository": artifact["repository"],
        "revision": artifact["revision"],
        "source_manifest_sha256": sha256_file(bundled_manifest),
    }
    if receipt.get("schema_version") != 1 or any(
        receipt.get(name) != value for name, value in receipt_identity.items()
    ):
        raise SystemExit("production model receipt disagrees with bundled manifest")
    expected, expected_digest = expected_snapshot(artifact)
    expected_by_path = {item["path"]: item for item in expected}
    actual = directory_inventory(model_directory)
    actual_by_path = {item["path"]: item for item in actual}

    mismatches = []
    for path, declaration in expected_by_path.items():
        found = actual_by_path.get(path)
        if (
            found is None
            or found["size"] != declaration["size"]
            or found["sha256"] != declaration["sha256"]
        ):
            mismatches.append(path)
    allowed_extras: set[str] = set()
    for distribution in distribution_files(artifact["license"]):
        allowed_extras.add(distribution["path"])
        if distribution["path"] not in expected_by_path:
            found = actual_by_path.get(distribution["path"])
            if (
                found is None
                or found["size"] != distribution["size"]
                or found["sha256"] != distribution["sha256"]
            ):
                mismatches.append(distribution["path"])
    notice = notice_file(artifact["license"])
    if notice is not None:
        allowed_extras.add(notice["path"])
        if notice["path"] not in expected_by_path:
            found = actual_by_path.get(notice["path"])
            if (
                found is None
                or found["size"] != notice["size"]
                or found["sha256"] != notice["sha256"]
            ):
                mismatches.append(notice["path"])
    # A shipped bundle cannot contain source-cache bookkeeping. The fail-
    # closed walker also rejects file/directory symlinks and special entries
    # before this extras comparison.
    all_bundle_files = [
        item["path"] for item in full_directory_inventory(model_directory)
    ]
    extras = sorted(set(all_bundle_files) - set(expected_by_path))
    unsupported_extras = sorted(set(extras) - allowed_extras)
    core_inventory = [
        actual_by_path[item["path"]]
        for item in expected
        if item["path"] in actual_by_path
    ]
    core_digest = (
        directory_digest(core_inventory)
        if len(core_inventory) == len(expected)
        else None
    )
    if mismatches or unsupported_extras or core_digest != expected_digest:
        raise SystemExit(
            f"{args.configuration} model verification failed: "
            f"mismatches={mismatches}, unsupported_extras={unsupported_extras}, "
            f"digest={core_digest}, expected={expected_digest}"
        )
    complete_inventory = full_directory_inventory(model_directory)
    if (
        receipt.get("file_count") != len(complete_inventory)
        or receipt.get("directory_sha256")
        != directory_digest(complete_inventory)
    ):
        raise SystemExit("production model receipt disagrees with bundled SQLModel")

    report_directory = create_run_directory(
        args.reports_dir.resolve(), args.run_id
    )
    report = {
        "schema_version": 1,
        "run_id": args.run_id,
        "status": "complete",
        "configuration": args.configuration,
        "app": str(app),
        "production": production,
        "model": {
            "key": artifact["key"],
            "repository": artifact["repository"],
            "revision": artifact["revision"],
            "expected_directory_sha256": expected_digest,
            "verified_directory_sha256": core_digest,
            "verified_file_count": len(expected),
            "allowed_extra_distribution_files": extras,
            "bundle_bytes": sum(item["size"] for item in actual),
        },
        "inputs": {
            "source_manifest_sha256": sha256_file(MODEL_MANIFEST),
            "bundled_manifest_sha256": sha256_file(bundled_manifest),
            "production_receipt_sha256": sha256_file(bundled_receipt),
        },
    }
    write_json(report_directory / "report.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
