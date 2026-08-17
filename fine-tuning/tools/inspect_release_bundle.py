"""Verify CREG archive/export artifacts before TestFlight or release upload."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from contextlib import ExitStack
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
    notice_file,
    validate_artifact_declaration,
    validate_production_configuration,
)

DEFAULT_REPORTS = REPO_ROOT / "eval" / "build-verification"
MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
MODEL_RUNTIME_CONTRACT = REPO_ROOT / "model-runtime-contract.json"
CODESIGN = Path("/usr/bin/codesign")


def load_bundled_manifest(path: Path, configuration: str) -> dict[str, Any]:
    """Validate the common manifest schema while admitting Beta candidates.

    The training tooling's ``load_manifest`` deliberately accepts only a
    verified production selection. Export inspection also has to validate the
    generated ``debug-candidate`` manifest used by Beta/TestFlight.
    """
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read bundled model manifest {path}: {error}") from error
    if manifest.get("schema_version") != 1:
        raise SystemExit("bundled model manifest schema_version must be 1")
    models = manifest.get("models")
    if not isinstance(models, list) or not models:
        raise SystemExit("bundled model manifest must declare models")
    keys = [model.get("key") for model in models]
    if len(keys) != len(set(keys)) or any(not key for key in keys):
        raise SystemExit("bundled model manifest keys must be present and unique")
    try:
        for model in models:
            validate_artifact_declaration(model)
        production = manifest.get("production")
        if not isinstance(production, dict):
            raise SystemExit("bundled manifest has no production selection")
        validate_production_configuration(production, set(keys))
    except Exception as error:
        if isinstance(error, SystemExit):
            raise
        raise SystemExit(f"bundled model manifest is invalid: {error}") from error
    status = manifest.get("production_status")
    allowed_statuses = (
        {"verified", "debug-candidate"}
        if configuration in {"Debug", "Beta"}
        else {"verified"}
    )
    if status not in allowed_statuses:
        raise SystemExit(
            f"{configuration} does not allow production_status {status!r}"
        )
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--configuration",
        choices=("Debug", "Beta", "Release"),
        default="Release",
    )
    parser.add_argument(
        "--expected-source-revision",
        help="full Git revision expected in the app and bundled manifest",
    )
    parser.add_argument(
        "--expected-training-run",
        help="exact candidate training run selected during publisher preflight",
    )
    parser.add_argument("--reports-dir", type=Path, default=DEFAULT_REPORTS)
    args = parser.parse_args()
    if not any((args.app, args.archive, args.ipa)):
        parser.error("at least one of --app, --archive, or --ipa is required")
    if args.app and (args.archive or args.ipa):
        parser.error("--app cannot be combined with --archive or --ipa")
    return args


def expected_snapshot(
    artifact: dict[str, Any],
) -> tuple[list[dict[str, Any]], str]:
    conversion = artifact.get("conversion")
    if conversion is not None:
        return conversion["required_files"], conversion["directory_sha256"]
    return artifact["required_files"], artifact["snapshot_directory_sha256"]


def app_from_archive(archive: Path) -> Path:
    applications = archive.resolve() / "Products" / "Applications"
    apps = sorted(applications.glob("*.app"))
    if len(apps) != 1:
        raise SystemExit(
            f"archive must contain exactly one Products/Applications/*.app: {archive}"
        )
    return apps[0]


def app_from_ipa(ipa: Path, scratch: Path) -> Path:
    with zipfile.ZipFile(ipa.resolve()) as archive:
        unsafe = [
            name
            for name in archive.namelist()
            if Path(name).is_absolute() or ".." in Path(name).parts
        ]
        if unsafe:
            raise SystemExit(f"IPA contains unsafe paths: {unsafe[:3]}")
        archive.extractall(scratch)
    apps = sorted((scratch / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise SystemExit(f"IPA must contain exactly one Payload/*.app: {ipa}")
    return apps[0]


def selected_artifact(
    manifest: dict[str, Any],
    configuration: str,
    info: dict[str, Any],
    expected_training_run: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    production = manifest.get("production")
    if not isinstance(production, dict):
        raise SystemExit("bundled manifest has no production selection")

    expected_channel = configuration.lower()
    if info.get("CREGBuildChannel") != expected_channel:
        raise SystemExit(
            "Info.plist build channel disagrees with configuration "
            f"({info.get('CREGBuildChannel')!r} != {expected_channel!r})"
        )

    if configuration == "Release":
        if (
            manifest.get("production_status") != "verified"
            or production.get("policy_version") != "bounded-three-generation-v1"
            or manifest.get("debug_candidate") is not None
        ):
            raise SystemExit(
                "Release requires a verified bounded-policy production selection"
            )
    else:
        status = manifest.get("production_status")
        candidate = manifest.get("debug_candidate")
        if status == "verified" and candidate is not None:
            raise SystemExit(
                f"{configuration} verified selection must not declare debug_candidate"
            )
        if status == "debug-candidate" and (
            not isinstance(candidate, dict)
            or candidate.get("model_key") != production.get("model_key")
            or not isinstance(candidate.get("base_model_key"), str)
            or not candidate.get("base_model_key")
            or not isinstance(candidate.get("training_run_id"), str)
            or not candidate.get("training_run_id")
            or not isinstance(candidate.get("selected_iteration"), int)
            or candidate.get("selected_iteration", 0) <= 0
            or re.fullmatch(
                r"[0-9a-f]{64}",
                str(candidate.get("selected_checkpoint_sha256", "")),
            )
            is None
            or candidate.get("wandb_receipt_required") is not False
        ):
            raise SystemExit(
                f"{configuration} debug-candidate identity is incomplete or inconsistent"
            )
        if expected_training_run is not None and (
            status != "debug-candidate"
            or candidate.get("training_run_id") != expected_training_run
        ):
            raise SystemExit(
                f"{configuration} candidate disagrees with publisher preflight"
            )

    try:
        artifact = next(
            model
            for model in manifest["models"]
            if model["key"] == production["model_key"]
        )
    except (KeyError, StopIteration) as error:
        raise SystemExit("selected model is not declared in bundled manifest") from error
    if configuration != "Release" and manifest.get("production_status") == "debug-candidate":
        candidate = manifest["debug_candidate"]
        if (
            artifact.get("training_run") != candidate["training_run_id"]
            or artifact.get("revision")
            != candidate["selected_checkpoint_sha256"][:40]
        ):
            raise SystemExit(
                f"{configuration} selected model disagrees with debug-candidate identity"
            )
    return production, artifact


def verify_runtime_contract(
    manifest: dict[str, Any],
    info: dict[str, Any],
    *,
    configuration: str,
    expected_source_revision: str | None,
) -> dict[str, Any]:
    try:
        definition = json.loads(MODEL_RUNTIME_CONTRACT.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read canonical model runtime contract: {error}") from error
    version = definition.get("current_version")
    if definition.get("schema_version") != 1 or not isinstance(version, int):
        raise SystemExit("canonical model runtime contract is invalid")
    contract = manifest.get("model_runtime_contract")
    if not isinstance(contract, dict):
        raise SystemExit("bundled manifest is missing model_runtime_contract")
    source_revision = contract.get("source_revision")
    source_dirty = contract.get("source_dirty")
    if contract.get("version") != version:
        raise SystemExit("bundled manifest runtime contract version is unsupported")
    if not isinstance(source_revision, str) or re.fullmatch(
        r"[0-9a-f]{40}", source_revision
    ) is None:
        raise SystemExit("bundled manifest source revision is invalid")
    if not isinstance(source_dirty, bool):
        raise SystemExit("bundled manifest source_dirty must be a Boolean")
    if (
        info.get("CREGModelRuntimeContractVersion") != version
        or info.get("CREGSourceRevision") != source_revision
        or info.get("CREGSourceDirty") is not source_dirty
    ):
        raise SystemExit("Info.plist and bundled manifest provenance disagree")
    if expected_source_revision is not None and source_revision != expected_source_revision:
        raise SystemExit("bundled source revision disagrees with the expected Git revision")
    if configuration == "Beta" and source_dirty:
        raise SystemExit("Beta source provenance must be clean")
    return {
        "version": version,
        "source_revision": source_revision,
        "source_dirty": source_dirty,
    }


def run_codesign(arguments: list[str], description: str) -> None:
    if not CODESIGN.is_file():
        raise SystemExit(f"codesign is unavailable while {description}")
    completed = subprocess.run(
        [str(CODESIGN), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        check=False,
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip()
        suffix = f": {details}" if details else ""
        raise SystemExit(f"codesign failed while {description}{suffix}")


def verify_code_signature(app: Path) -> dict[str, Any]:
    run_codesign(
        ["--verify", "--deep", "--strict", "--verbose=2", str(app)],
        "verifying the app signature",
    )
    return {"status": "valid"}


def unsigned_executable_identity(executable: Path) -> dict[str, Any]:
    """Hash executable bytes after removing only the embedded signature."""
    with tempfile.TemporaryDirectory(prefix="creg-unsigned-executable-") as value:
        normalized = Path(value) / executable.name
        shutil.copyfile(executable, normalized)
        normalized.chmod((executable.stat().st_mode & 0o777) | 0o200)
        run_codesign(
            ["--remove-signature", str(normalized)],
            "normalizing the executable signature",
        )
        return {
            "bytes": normalized.stat().st_size,
            "sha256": hashlib.sha256(normalized.read_bytes()).hexdigest(),
        }


def verify_executable(app: Path, info: dict[str, Any]) -> dict[str, Any]:
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise SystemExit("Info.plist has no CFBundleExecutable")
    executable = app / executable_name
    if not executable.is_file() or executable.stat().st_size <= 0:
        raise SystemExit("bundle executable is missing or empty")
    signed_sha256 = sha256_file(executable)
    unsigned = unsigned_executable_identity(executable)
    return {
        "relative_path": executable_name,
        "signed_bytes": executable.stat().st_size,
        "signed_sha256": signed_sha256,
        "unsigned_bytes": unsigned["bytes"],
        "unsigned_sha256": unsigned["sha256"],
    }


def verify_metal_resource(app: Path) -> dict[str, Any]:
    libraries = sorted(
        path
        for path in app.rglob("default.metallib")
        if path.parent.name == "mlx-swift_Cmlx.bundle"
    )
    if len(libraries) != 1 or libraries[0].stat().st_size <= 0:
        raise SystemExit(
            "bundle must contain exactly one non-empty "
            "mlx-swift_Cmlx.bundle/default.metallib"
        )
    return {
        "relative_path": str(libraries[0].relative_to(app)),
        "bytes": libraries[0].stat().st_size,
        "sha256": sha256_file(libraries[0]),
    }


def verify_app(
    app: Path,
    *,
    configuration: str,
    expected_source_revision: str | None = None,
    expected_training_run: str | None = None,
) -> dict[str, Any]:
    app = app.resolve()
    bundled_manifest = app / "model-manifest.json"
    bundled_receipt = app / "production-model-receipt.json"
    model_directory = app / "SQLModel"
    info_path = app / "Info.plist"
    if not all(
        (
            bundled_manifest.is_file(),
            bundled_receipt.is_file(),
            model_directory.is_dir(),
            info_path.is_file(),
        )
    ):
        raise SystemExit(
            f"{configuration} bundle is missing Info.plist, model-manifest.json, "
            f"production-model-receipt.json, or SQLModel: {app}"
        )
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    manifest = load_bundled_manifest(bundled_manifest, configuration)
    if configuration == "Release":
        source_manifest = json.loads(MODEL_MANIFEST.read_text())
        unstamped_manifest = dict(manifest)
        unstamped_manifest.pop("model_runtime_contract", None)
        if unstamped_manifest != source_manifest:
            raise SystemExit("Release bundled model manifest differs from source")
    runtime_contract = verify_runtime_contract(
        manifest,
        info,
        configuration=configuration,
        expected_source_revision=expected_source_revision,
    )
    production, artifact = selected_artifact(
        manifest,
        configuration,
        info,
        expected_training_run,
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
        raise SystemExit("model receipt disagrees with bundled manifest")

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
            f"{configuration} model verification failed: "
            f"mismatches={mismatches}, unsupported_extras={unsupported_extras}, "
            f"digest={core_digest}, expected={expected_digest}"
        )
    complete_inventory = full_directory_inventory(model_directory)
    complete_digest = directory_digest(complete_inventory)
    if (
        receipt.get("file_count") != len(complete_inventory)
        or receipt.get("directory_sha256") != complete_digest
    ):
        raise SystemExit("model receipt disagrees with bundled SQLModel")

    return {
        "app": str(app),
        "bundle_identifier": info.get("CFBundleIdentifier"),
        "marketing_version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
        "build_channel": info.get("CREGBuildChannel"),
        "model_runtime_contract": runtime_contract,
        "production": production,
        "debug_candidate": manifest.get("debug_candidate"),
        "model": {
            "key": artifact["key"],
            "repository": artifact["repository"],
            "revision": artifact["revision"],
            "expected_directory_sha256": expected_digest,
            "verified_directory_sha256": core_digest,
            "receipt_directory_sha256": complete_digest,
            "verified_file_count": len(expected),
            "receipt_file_count": len(complete_inventory),
            "allowed_extra_distribution_files": extras,
            "bundle_bytes": sum(item["size"] for item in actual),
        },
        "executable": verify_executable(app, info),
        "code_signature": verify_code_signature(app),
        "metal": verify_metal_resource(app),
        "inputs": {
            "bundled_manifest_sha256": sha256_file(bundled_manifest),
            "production_receipt_sha256": sha256_file(bundled_receipt),
        },
    }


def main() -> None:
    args = parse_args()
    artifacts: list[dict[str, Any]] = []
    with ExitStack() as stack:
        if args.app:
            inputs = [("app", args.app.resolve())]
        else:
            inputs = []
            if args.archive:
                inputs.append(("archive", app_from_archive(args.archive)))
            if args.ipa:
                scratch = Path(stack.enter_context(tempfile.TemporaryDirectory()))
                inputs.append(("ipa", app_from_ipa(args.ipa, scratch)))
        for kind, app in inputs:
            result = verify_app(
                app,
                configuration=args.configuration,
                expected_source_revision=args.expected_source_revision,
                expected_training_run=args.expected_training_run,
            )
            result["artifact_kind"] = kind
            artifacts.append(result)

    report = {
        "schema_version": 3,
        "run_id": args.run_id,
        "status": "complete",
        "configuration": args.configuration,
        "artifacts": artifacts,
    }
    report_directory = create_run_directory(
        args.reports_dir.resolve(), args.run_id
    )
    write_json(report_directory / "report.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
