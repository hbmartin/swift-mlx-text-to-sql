"""Materialize immutable model artifacts declared in model-manifest.json.

The manifest, not a command-line repository string, is the source of truth.
All Hugging Face snapshots are fetched at a 40-character commit revision and
verified before use. XiYanSQL is converted to the declared MLX quantization
configuration after its source snapshot is verified.

Examples:
  uv run python tools/fetch_model.py --all
  uv run python tools/fetch_model.py --model qwen25-coder-3b
  uv run python tools/fetch_model.py --production --destination /tmp/SQLModel
  uv run python tools/fetch_model.py --all --verify-only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any

# Xcode and the documented CLI invoke this file directly. In that mode Python
# places `tools/`, not `fine-tuning/`, on sys.path; add the package root before
# importing the shared integrity module.
if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from huggingface_hub import hf_hub_download, snapshot_download

from eval.file_integrity import (
    IntegrityError as ArtifactError,
    canonical_json,
    directory_digest as integrity_directory_digest,
    directory_inventory as integrity_directory_inventory,
    regular_files,
    sha256_file,
    transactionally_replace_directory,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "model-manifest.json"
DEFAULT_MODELS_DIR = REPO_ROOT / "models"
LOCK_FILE = ".creg-artifact.json"
PRODUCTION_RECEIPT_FILE = "production-model-receipt.json"


def artifact_files(directory: Path) -> list[Path]:
    return regular_files(
        directory,
        include=lambda relative: (
            relative.name != LOCK_FILE and ".cache" not in relative.parts
        ),
    )


def directory_inventory(directory: Path) -> list[dict[str, Any]]:
    return integrity_directory_inventory(
        directory,
        include=lambda relative: (
            relative.name != LOCK_FILE and ".cache" not in relative.parts
        ),
    )


def directory_digest(inventory: list[dict[str, Any]]) -> str:
    return integrity_directory_digest(inventory)


def declared_directory_sha256(artifact: dict[str, Any]) -> str:
    """The manifest-declared digest of the tree a consumer actually loads."""
    conversion = artifact.get("conversion")
    if conversion is not None:
        return conversion["directory_sha256"]
    return artifact["snapshot_directory_sha256"]


def verify_artifact_tree_at_use(
    directory: Path, artifact: dict[str, Any]
) -> str:
    """Re-hash an artifact tree at time of use.

    The lock file records what was true at fetch time; a consumer that is
    about to train on or evaluate these bytes must not copy that claim
    forward without re-verifying it.
    """
    lock_path = directory / LOCK_FILE
    if not directory.is_dir() or not lock_path.is_file():
        raise ArtifactError(
            f"verified model is missing: {directory}; run fetch_model.py first"
        )
    lock = json.loads(lock_path.read_text())
    actual = directory_digest(directory_inventory(directory))
    declared = declared_directory_sha256(artifact)
    if actual != declared:
        raise ArtifactError(
            f"{directory}: tree sha256 {actual} does not match the manifest "
            f"declaration {declared}; re-run fetch_model.py"
        )
    if lock.get("directory_sha256") != actual:
        raise ArtifactError(
            f"{directory}: artifact lock is stale "
            f"({lock.get('directory_sha256')} != {actual}); re-run "
            "fetch_model.py"
        )
    return actual


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ArtifactError(f"cannot read model manifest {path}: {error}") from error
    if manifest.get("schema_version") != 1:
        raise ArtifactError("model manifest schema_version must be 1")
    keys = [model.get("key") for model in manifest.get("models", [])]
    if len(keys) != len(set(keys)) or any(not key for key in keys):
        raise ArtifactError("model manifest keys must be present and unique")
    for model in manifest.get("models", []):
        validate_artifact_declaration(model)
    production = manifest.get("production")
    if production is not None:
        validate_production_configuration(production, set(keys))
        if manifest.get("production_status") != "verified":
            raise ArtifactError(
                "a production selection requires production_status 'verified'"
            )
    elif manifest.get("production_status") != "selection_pending":
        raise ArtifactError(
            "a null production selection requires production_status "
            "'selection_pending'"
        )
    return manifest


def distribution_files(
    license_declaration: dict[str, Any],
) -> list[dict[str, Any]]:
    """Normalize singular and multi-license distribution declarations."""
    singular = license_declaration.get("required_distribution_file")
    plural = license_declaration.get("required_distribution_files")
    if singular is not None and plural is not None:
        raise ArtifactError(
            "license declaration cannot contain both singular and plural "
            "distribution-file fields"
        )
    declared = plural if plural is not None else ([singular] if singular else [])
    if not isinstance(declared, list):
        raise ArtifactError("required_distribution_files must be a list")
    normalized = []
    for item in declared:
        if not isinstance(item, dict):
            raise ArtifactError(
                "distribution license declaration must be an object"
            )
        normalized.append(
            {
                **item,
                "source_repository": item.get("source_repository")
                or license_declaration.get("source_repository"),
                "source_revision": item.get("source_revision")
                or license_declaration.get("source_revision"),
                "source_path": item.get("source_path") or item.get("path"),
            }
        )
    paths = [item.get("path") for item in normalized]
    if len(paths) != len(set(paths)):
        raise ArtifactError(
            "distribution license destination paths must be unique"
        )
    return normalized


def notice_file(
    license_declaration: dict[str, Any],
) -> dict[str, Any] | None:
    declared = license_declaration.get("required_notice_file")
    if declared is None:
        return None
    if not isinstance(declared, dict):
        raise ArtifactError("required_notice_file must be an object")
    return {
        **declared,
        "source_path": declared.get("source_path") or declared.get("path"),
    }


def validate_artifact_declaration(artifact: dict[str, Any]) -> None:
    local_unpublished = (
        artifact.get("derived") is True
        and artifact.get("publication_status") == "local-unpublished"
    )
    revision = artifact.get("revision")
    repository = artifact.get("repository")
    if local_unpublished:
        if repository is not None or revision is not None:
            raise ArtifactError(
                f"{artifact.get('key')}: unpublished local artifact cannot claim "
                "a repository or revision"
            )
        if not artifact.get("training_run"):
            raise ArtifactError(
                f"{artifact.get('key')}: unpublished local artifact needs training_run"
            )
    elif (
        not isinstance(revision, str)
        or len(revision) != 40
        or any(c not in "0123456789abcdef" for c in revision)
    ):
        raise ArtifactError(
            f"{artifact.get('key', repository)}: revision must be "
            "a lowercase 40-character commit hash"
        )
    if (not local_unpublished and not repository) or not artifact.get(
        "local_directory"
    ):
        raise ArtifactError("every published artifact needs repository and local_directory")
    label = repository or artifact["key"]
    license_declaration = artifact.get("license")
    if (
        not isinstance(license_declaration, dict)
        or not license_declaration.get("id")
        or not isinstance(license_declaration.get("commercial_use"), bool)
        or not license_declaration.get("url")
    ):
        raise ArtifactError(f"{label}: complete license metadata required")
    declared_licenses = distribution_files(license_declaration)
    declared_notice = notice_file(license_declaration)
    if "qwen-research" in license_declaration["id"]:
        if not declared_licenses:
            raise ArtifactError(
                f"{label}: Qwen Research License distribution file required"
            )
        if declared_notice is None:
            raise ArtifactError(
                f"{label}: Qwen attribution NOTICE file required"
            )
    for distribution_file in declared_licenses:
        if not distribution_file.get("source_repository"):
            raise ArtifactError(
                f"{label}: license source_repository required"
            )
        source_revision = distribution_file.get("source_revision", "")
        if len(source_revision) != 40 or any(
            c not in "0123456789abcdef" for c in source_revision
        ):
            raise ArtifactError(
                f"{label}: license source_revision must be pinned"
            )
        validate_file_declarations(
            f"{label} distribution license",
            [distribution_file],
        )
        if not distribution_file.get("source_path"):
            raise ArtifactError(
                f"{label}: distribution license source_path required"
            )
    if declared_notice is not None:
        validate_file_declarations(
            f"{label} attribution notice",
            [declared_notice],
        )
        if not declared_notice.get("source_path"):
            raise ArtifactError(
                f"{label}: attribution notice source_path required"
            )
    required = artifact.get("required_files")
    if not isinstance(required, list) or not required:
        raise ArtifactError(f"{label}: required_files cannot be empty")
    validate_file_declarations(label, required)
    validate_digest(
        label,
        "snapshot_directory_sha256",
        artifact.get("snapshot_directory_sha256"),
    )
    conversion = artifact.get("conversion")
    if conversion is not None:
        converted_required = conversion.get("required_files")
        if not isinstance(converted_required, list) or not converted_required:
            raise ArtifactError(
                f"{label}: conversion.required_files cannot be empty"
            )
        validate_file_declarations(
            f"{label} converted artifact", converted_required
        )
        validate_digest(
            label,
            "conversion.directory_sha256",
            conversion.get("directory_sha256"),
        )


def validate_digest(label: str, field: str, value: Any) -> None:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(c not in "0123456789abcdef" for c in value)
    ):
        raise ArtifactError(f"{label}: {field} must be a lowercase SHA-256 digest")


def validate_file_declarations(
    label: str, declarations: list[dict[str, Any]]
) -> None:
    for declaration in declarations:
        relative = Path(declaration.get("path", ""))
        if (
            not declaration.get("path")
            or relative.is_absolute()
            or ".." in relative.parts
        ):
            raise ArtifactError(
                f"{label}: unsafe required file path {relative}"
            )
        expected_hash = declaration.get("sha256")
        if (
            not isinstance(expected_hash, str)
            or
            len(expected_hash) != 64
            or any(c not in "0123456789abcdef" for c in expected_hash)
        ):
            raise ArtifactError(f"{label}:{relative}: sha256 is required and invalid")
        expected_size = declaration.get("size")
        if not isinstance(expected_size, int) or expected_size < 0:
            raise ArtifactError(f"{label}:{relative}: non-negative size is required")


def validate_production_configuration(
    production: dict[str, Any], model_keys: set[str]
) -> None:
    key = production.get("model_key")
    if key not in model_keys:
        raise ArtifactError(
            f"production model_key {key!r} is not declared in models"
        )
    if production.get("gcd") not in {"on", "off"}:
        raise ArtifactError("production gcd must be 'on' or 'off'")
    temperature = production.get("temperature")
    if not isinstance(temperature, (int, float)) or not 0 <= temperature <= 1:
        raise ArtifactError("production temperature must be in [0, 1]")
    if production.get("top_p") != 1.0 or production.get("top_k") != 0:
        raise ArtifactError("production requires top_p 1.0 and disabled top_k")
    if not isinstance(production.get("max_tokens"), int) or production["max_tokens"] <= 0:
        raise ArtifactError("production max_tokens must be a positive integer")
    voting = production.get("voting")
    if not isinstance(voting, dict):
        raise ArtifactError("production voting configuration is required")
    if (
        not isinstance(voting.get("candidate_count"), int)
        or voting["candidate_count"] < 1
    ):
        raise ArtifactError("voting candidate_count must be at least one")
    sample_temperature = voting.get("sample_temperature")
    if (
        not isinstance(sample_temperature, (int, float))
        or not 0 <= sample_temperature <= 1
    ):
        raise ArtifactError("voting sample_temperature must be in [0, 1]")
    if not isinstance(voting.get("always_vote"), bool):
        raise ArtifactError("voting always_vote must be a boolean")
    policy_version = production.get("policy_version")
    if policy_version is not None and (
        policy_version != "bounded-three-generation-v1"
        or voting["candidate_count"] != 3
        or sample_temperature != 0.7
        or voting["always_vote"] is not False
    ):
        raise ArtifactError(
            "bounded-three-generation-v1 requires three generations, "
            "sample temperature 0.7, and always_vote=false"
        )


def verify_declared_files(
    directory: Path, declarations: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    verified: list[dict[str, Any]] = []
    for declaration in declarations:
        relative = Path(declaration["path"])
        path = directory / relative
        if not path.is_file():
            raise ArtifactError(f"missing required model file: {path}")
        actual_size = path.stat().st_size
        expected_size = declaration.get("size")
        if expected_size is not None and actual_size != expected_size:
            raise ArtifactError(
                f"{path}: expected {expected_size} bytes, found {actual_size}"
            )
        actual_hash = sha256_file(path)
        expected_hash = declaration.get("sha256")
        if expected_hash is not None and actual_hash != expected_hash:
            raise ArtifactError(
                f"{path}: expected sha256 {expected_hash}, found {actual_hash}"
            )
        verified.append(
            {"path": relative.as_posix(), "size": actual_size, "sha256": actual_hash}
        )
    return verified


def verify_required_files(directory: Path, artifact: dict[str, Any]) -> dict[str, Any]:
    verified = verify_declared_files(directory, artifact["required_files"])
    inventory = directory_inventory(directory)
    actual_directory_hash = directory_digest(inventory)
    expected_directory_hash = artifact["snapshot_directory_sha256"]
    if actual_directory_hash != expected_directory_hash:
        raise ArtifactError(
            f"{directory}: expected directory sha256 {expected_directory_hash}, "
            f"found {actual_directory_hash}"
        )
    lock = {
        "schema_version": 1,
        "key": artifact.get("key"),
        "repository": artifact["repository"],
        "revision": artifact["revision"],
        "format": artifact["format"],
        "verified_files": verified,
        "all_files": inventory,
        "directory_sha256": actual_directory_hash,
        "declaration_sha256": hashlib.sha256(
            canonical_json(artifact)
        ).hexdigest(),
    }
    if artifact.get("training_provenance") is not None:
        lock["training_provenance"] = artifact["training_provenance"]
    return lock


def write_lock(directory: Path, lock: dict[str, Any]) -> None:
    (directory / LOCK_FILE).write_text(
        json.dumps(lock, indent=2, sort_keys=True) + "\n"
    )


def fetch_snapshot(
    artifact: dict[str, Any],
    models_dir: Path,
    *,
    local_files_only: bool,
    verify_only: bool,
) -> Path:
    destination = models_dir / artifact["local_directory"]
    local_unpublished = (
        artifact.get("derived") is True
        and artifact.get("publication_status") == "local-unpublished"
    )
    if local_unpublished and not verify_only:
        print(
            f"verifying unpublished local training artifact {artifact['key']} -> "
            f"{destination}",
            flush=True,
        )
    if not verify_only:
        if not local_unpublished:
            destination.parent.mkdir(parents=True, exist_ok=True)
            print(
                f"fetching {artifact['repository']}@{artifact['revision']} -> "
                f"{destination}",
                flush=True,
            )
            snapshot_download(
                repo_id=artifact["repository"],
                revision=artifact["revision"],
                local_dir=destination,
                local_files_only=local_files_only,
            )
    if not destination.is_dir():
        mode = "cache-only" if local_files_only else "verify-only"
        raise ArtifactError(f"{mode}: model directory does not exist: {destination}")
    lock = verify_required_files(destination, artifact)
    write_lock(destination, lock)
    print(
        f"verified {artifact.get('repository') or artifact['key']}@"
        f"{artifact.get('revision') or artifact['snapshot_directory_sha256']} "
        f"({len(lock['verified_files'])} required files)",
        flush=True,
    )
    return destination


def convert_xiyan(
    source: Path,
    artifact: dict[str, Any],
    models_dir: Path,
    *,
    verify_only: bool,
) -> Path:
    conversion = artifact["conversion"]
    destination = models_dir / conversion["output_directory"]
    if not verify_only and not destination.is_dir():
        command = [
            sys.executable,
            "-m",
            "mlx_lm",
            "convert",
            "--hf-path",
            str(source),
            "--mlx-path",
            str(destination),
            "--dtype",
            conversion["dtype"],
            "--quantize",
            "--q-bits",
            str(conversion["bits"]),
            "--q-group-size",
            str(conversion["group_size"]),
            "--q-mode",
            conversion["mode"],
        ]
        print("converting XiYanSQL: " + " ".join(command), flush=True)
        subprocess.run(command, check=True)
    if not destination.is_dir():
        raise ArtifactError(f"converted XiYanSQL directory is missing: {destination}")
    verified = verify_declared_files(destination, conversion["required_files"])
    files = directory_inventory(destination)
    actual_directory_hash = directory_digest(files)
    if actual_directory_hash != conversion["directory_sha256"]:
        raise ArtifactError(
            f"{destination}: expected directory sha256 "
            f"{conversion['directory_sha256']}, found {actual_directory_hash}"
        )
    source_lock = json.loads((source / LOCK_FILE).read_text())
    lock = {
        "schema_version": 1,
        "key": artifact["key"],
        "repository": artifact["repository"],
        "revision": artifact["revision"],
        "format": "mlx",
        "source_directory": source.name,
        "source_directory_sha256": source_lock["directory_sha256"],
        "conversion": conversion,
        "verified_files": verified,
        "all_files": files,
        "directory_sha256": actual_directory_hash,
        "declaration_sha256": hashlib.sha256(
            canonical_json(artifact)
        ).hexdigest(),
    }
    write_lock(destination, lock)
    print(f"verified converted XiYanSQL artifact: {destination}", flush=True)
    return destination


def materialize(
    artifact: dict[str, Any],
    models_dir: Path,
    *,
    local_files_only: bool,
    verify_only: bool,
) -> Path:
    source = fetch_snapshot(
        artifact,
        models_dir,
        local_files_only=local_files_only,
        verify_only=verify_only,
    )
    if artifact["format"] == "transformers-bfloat16":
        return convert_xiyan(
            source, artifact, models_dir, verify_only=verify_only
        )
    if artifact["format"] != "mlx":
        raise ArtifactError(f"unsupported model format: {artifact['format']}")
    return source


def copy_distribution_license(
    artifact: dict[str, Any],
    destination: Path,
    *,
    local_files_only: bool,
) -> None:
    for declared_file in distribution_files(artifact["license"]):
        source = Path(
            hf_hub_download(
                repo_id=declared_file["source_repository"],
                filename=declared_file["source_path"],
                revision=declared_file["source_revision"],
                local_files_only=local_files_only,
            )
        )
        if source.stat().st_size != declared_file["size"]:
            raise ArtifactError(
                f"{source}: distribution license size mismatch"
            )
        if sha256_file(source) != declared_file["sha256"]:
            raise ArtifactError(
                f"{source}: distribution license hash mismatch"
            )
        target = destination / declared_file["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    declared_notice = notice_file(artifact["license"])
    if declared_notice is not None:
        source = REPO_ROOT / declared_notice["source_path"]
        if (
            not source.is_file()
            or source.stat().st_size != declared_notice["size"]
            or sha256_file(source) != declared_notice["sha256"]
        ):
            raise ArtifactError(
                f"{source}: attribution notice verification failed"
            )
        target = destination / declared_notice["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def full_directory_inventory(directory: Path) -> list[dict[str, Any]]:
    """Inventory every real file, including paths ignored in model caches."""
    return integrity_directory_inventory(directory)


def expected_production_inventory(
    source: Path, artifact: dict[str, Any]
) -> list[dict[str, Any]]:
    """The exact files produced by copy_production, excluding bookkeeping."""
    expected = {item["path"]: item for item in directory_inventory(source)}
    for item in distribution_files(artifact["license"]):
        expected[item["path"]] = {
            "path": item["path"],
            "size": item["size"],
            "sha256": item["sha256"],
        }
    if (item := notice_file(artifact["license"])) is not None:
        expected[item["path"]] = {
            "path": item["path"],
            "size": item["size"],
            "sha256": item["sha256"],
        }
    return sorted(expected.values(), key=lambda item: item["path"])


def verify_replaceable_production_destination(
    source: Path,
    destination: Path,
    artifact: dict[str, Any],
) -> None:
    """Refuse to delete anything except an exact prior materialization."""
    if destination.is_symlink() or not destination.is_dir():
        raise ArtifactError(
            f"refusing to delete {destination}: it is not a real directory"
        )
    if not any(destination.iterdir()):
        return

    expected = expected_production_inventory(source, artifact)
    actual = full_directory_inventory(destination)
    actual_by_path = {item["path"]: item for item in actual}

    # Bundles created before the lock was excluded may contain the exact
    # source lock. Accept only that byte-identical legacy bookkeeping file.
    legacy_lock = actual_by_path.pop(LOCK_FILE, None)
    source_lock = source / LOCK_FILE
    if legacy_lock is not None:
        expected_legacy_lock = (
            {
                "path": LOCK_FILE,
                "size": source_lock.stat().st_size,
                "sha256": sha256_file(source_lock),
            }
            if source_lock.is_file()
            else None
        )
        if legacy_lock != expected_legacy_lock:
            raise ArtifactError(
                f"refusing to delete {destination}: its artifact lock does "
                "not match the verified source"
            )

    normalized_actual = sorted(
        actual_by_path.values(), key=lambda item: item["path"]
    )
    if normalized_actual != expected:
        expected_by_path = {item["path"]: item for item in expected}
        actual_paths = set(actual_by_path)
        expected_paths = set(expected_by_path)
        mismatches = sorted(
            path
            for path in actual_paths & expected_paths
            if actual_by_path[path] != expected_by_path[path]
        )
        raise ArtifactError(
            f"refusing to delete {destination}: it is not an exact prior "
            "production bundle "
            f"(missing={sorted(expected_paths - actual_paths)}, "
            f"extra={sorted(actual_paths - expected_paths)}, "
            f"mismatched={mismatches})"
        )


def copy_production(
    source: Path,
    destination: Path,
    artifact: dict[str, Any],
    *,
    local_files_only: bool,
    source_manifest: Path | None = None,
    receipt_destination: Path | None = None,
) -> None:
    source_resolved = source.resolve()
    destination_resolved = destination.resolve()
    if (
        source_resolved == destination_resolved
        or source_resolved in destination_resolved.parents
        or destination_resolved in source_resolved.parents
    ):
        raise ArtifactError(
            "production source and destination must be disjoint: "
            f"{source} -> {destination}"
        )
    if destination.is_symlink():
        raise ArtifactError(
            f"refusing to replace symbolic-link destination: {destination}"
        )
    if destination.exists():
        verify_replaceable_production_destination(
            source, destination, artifact
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Fail closed before copytree can follow a source link hidden by an
    # exclusion. The same-parent staging directory makes the final rename
    # atomic on the destination filesystem.
    full_directory_inventory(source)
    staging = Path(tempfile.mkdtemp(
        prefix=f".{destination.name}.staging-",
        dir=destination.parent,
    ))
    try:
        # The artifact lock is fetch-time bookkeeping, not model content; the
        # shipped bundle contains exactly the manifest tree plus license files.
        shutil.copytree(
            source,
            staging,
            dirs_exist_ok=True,
            symlinks=True,
            ignore=shutil.ignore_patterns(".cache", LOCK_FILE),
        )
        copy_distribution_license(
            artifact,
            staging,
            local_files_only=local_files_only,
        )
        actual = full_directory_inventory(staging)
        expected = expected_production_inventory(source, artifact)
        if actual != expected:
            raise ArtifactError(
                f"staged production inventory does not match expected bytes: "
                f"{staging}"
            )
        transactionally_replace_directory(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    if source_manifest is not None:
        receipt_destination = receipt_destination or (
            destination.parent / PRODUCTION_RECEIPT_FILE
        )
        installed = full_directory_inventory(destination)
        receipt = {
            "schema_version": 1,
            "model_key": artifact["key"],
            "repository": artifact["repository"],
            "revision": artifact["revision"],
            "directory_sha256": directory_digest(installed),
            "file_count": len(installed),
            "source_manifest_sha256": sha256_file(source_manifest),
        }
        receipt_destination.parent.mkdir(parents=True, exist_ok=True)
        receipt_stage = receipt_destination.with_name(
            f".{receipt_destination.name}.staging-{uuid.uuid4().hex}"
        )
        try:
            receipt_stage.write_bytes(canonical_json(receipt) + b"\n")
            sha256_file(receipt_stage)
            receipt_stage.replace(receipt_destination)
        finally:
            if receipt_stage.exists():
                receipt_stage.unlink()
    print(f"materialized production model -> {destination}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--all", action="store_true", help="fetch all candidates")
    selection.add_argument("--model", help="fetch one manifest model key")
    selection.add_argument(
        "--production", action="store_true", help="fetch the selected production model"
    )
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR)
    parser.add_argument(
        "--destination",
        type=Path,
        help="copy the verified production model to this bundle directory",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="verify local artifacts without downloading or converting",
    )
    parser.add_argument(
        "--local-files-only",
        action="store_true",
        help="forbid network access and use only the Hugging Face/local cache",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest = load_manifest(args.manifest.resolve())
    models_dir = args.models_dir.resolve()

    if args.production:
        production = manifest.get("production")
        if production is None:
            raise ArtifactError(
                "production model selection is pending; run the evaluation matrix "
                "and update model-manifest.json before building Release"
            )
        if production.get("policy_version") != "bounded-three-generation-v1":
            raise ArtifactError(
                "the selected production model has historical policy evidence; "
                "schema-v3 bounded-policy calibration and finalization are required"
            )
        artifact = next(
            model
            for model in manifest["models"]
            if model["key"] == production["model_key"]
        )
        source = materialize(
            artifact,
            models_dir,
            local_files_only=args.local_files_only,
            verify_only=args.verify_only,
        )
        if args.destination is not None:
            copy_production(
                source,
                args.destination.resolve(),
                artifact,
                local_files_only=args.local_files_only,
                source_manifest=args.manifest.resolve(),
            )
        return

    models = {model["key"]: model for model in manifest["models"]}
    if args.all:
        selected = list(models.values())
    else:
        if args.model not in models:
            raise ArtifactError(
                f"unknown model key {args.model!r}; choose one of {sorted(models)}"
            )
        selected = [models[args.model]]
    for artifact in selected:
        materialize(
            artifact,
            models_dir,
            local_files_only=args.local_files_only,
            verify_only=args.verify_only,
        )


if __name__ == "__main__":
    try:
        main()
    except (ArtifactError, subprocess.CalledProcessError) as error:
        print(f"model materialization failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
