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
from pathlib import Path
from typing import Any

from huggingface_hub import hf_hub_download, snapshot_download

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "model-manifest.json"
DEFAULT_MODELS_DIR = REPO_ROOT / "models"
LOCK_FILE = ".creg-artifact.json"


class ArtifactError(RuntimeError):
    """The declared artifact could not be fetched or verified."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()


def artifact_files(directory: Path) -> list[Path]:
    return sorted(
        path
        for path in directory.rglob("*")
        if path.is_file()
        and path.name != LOCK_FILE
        and ".cache" not in path.relative_to(directory).parts
    )


def directory_inventory(directory: Path) -> list[dict[str, Any]]:
    return [
        {
            "path": path.relative_to(directory).as_posix(),
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in artifact_files(directory)
    ]


def directory_digest(inventory: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_json(inventory)).hexdigest()


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


def copy_production(
    source: Path,
    destination: Path,
    artifact: dict[str, Any],
    *,
    local_files_only: bool,
) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        source,
        destination,
        symlinks=False,
        ignore=shutil.ignore_patterns(".cache"),
    )
    copy_distribution_license(
        artifact,
        destination,
        local_files_only=local_files_only,
    )
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
