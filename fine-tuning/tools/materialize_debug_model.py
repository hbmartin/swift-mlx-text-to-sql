"""Bundle an explicitly experimental local reliability-v3 model in Debug.

This path deliberately does not require a W&B receipt. It does require the
immutable local training manifest, finite training numerics, a completed
multi-snapshot checkpoint evaluation, an intact selected adapter checkpoint,
and the exact manifest-pinned base model. The resulting fused model, generated
manifest, and bundle receipt are Debug evidence only and cannot satisfy the
Release production policy gate.
"""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Callable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from eval.file_integrity import (
    canonical_json,
    sha256_file,
    transactionally_replace_directory,
)
from tools.fetch_model import (
    ArtifactError,
    DEFAULT_MANIFEST,
    DEFAULT_MODELS_DIR,
    LOCK_FILE,
    PRODUCTION_RECEIPT_FILE,
    directory_digest,
    directory_inventory,
    distribution_files,
    full_directory_inventory,
    hf_hub_download,
    load_manifest,
    notice_file,
    verify_artifact_tree_at_use,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TRAINING_RUNS = REPO_ROOT / "eval" / "training-runs"
DEFAULT_FUSED_CACHE = DEFAULT_MODELS_DIR / "debug-fused"
ELIGIBLE_LOCAL_STATUSES = frozenset(
    {"local_complete", "awaiting_wandb", "wandb_complete", "complete"}
)
Runner = Callable[..., subprocess.CompletedProcess[Any]]


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = path.with_name(f".{path.name}.staging-{uuid.uuid4().hex}")
    try:
        staged.write_bytes(canonical_json(value) + b"\n")
        sha256_file(staged)
        staged.replace(path)
    finally:
        if staged.exists():
            staged.unlink()


def local_artifact_path(artifact: dict[str, Any], models_dir: Path) -> Path:
    conversion = artifact.get("conversion")
    directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    return models_dir / directory


def load_training_manifest(run_directory: Path) -> dict[str, Any]:
    manifest_path = run_directory / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ArtifactError(
            f"cannot read local training manifest {manifest_path}: {error}"
        ) from error
    return manifest


def is_reliability_v3(manifest: dict[str, Any]) -> bool:
    experiment = manifest.get("experiment", {})
    corpus = manifest.get("corpus", {}).get("variant", {})
    prompt = manifest.get("prompt_contract", {})
    return (
        (corpus.get("corpus_version") or experiment.get("corpus_version"))
        == "reliability-v3"
        and (prompt.get("prompt_version") or experiment.get("prompt_version"))
        == "reliability-v3"
        and (prompt.get("policy_version") or experiment.get("policy_version"))
        == "bounded-three-generation-v1"
    )


def select_latest_local_v3(training_runs: Path) -> Path:
    if not training_runs.is_dir():
        raise ArtifactError(f"training-runs directory is missing: {training_runs}")
    candidates: list[tuple[str, str, Path]] = []
    for directory in training_runs.iterdir():
        if directory.is_symlink() or not directory.is_dir():
            continue
        manifest_path = directory / "manifest.json"
        if not manifest_path.is_file():
            continue
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if (
            manifest.get("status") in ELIGIBLE_LOCAL_STATUSES
            and is_reliability_v3(manifest)
            and manifest.get("checkpoint_evaluation", {}).get("selected")
        ):
            candidates.append(
                (
                    str(manifest.get("started_at", "")),
                    str(manifest.get("run_id", directory.name)),
                    directory,
                )
            )
    if not candidates:
        raise ArtifactError(
            "no locally eligible reliability-v3 run has a selected checkpoint"
        )
    return max(candidates)[2]


def resolve_training_run(value: str, training_runs: Path) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_dir():
        return supplied.resolve()
    by_id = training_runs / value
    if by_id.is_dir():
        return by_id.resolve()
    raise ArtifactError(
        f"Debug training run is neither a directory nor a run id under "
        f"{training_runs}: {value}"
    )


def declared_adapter_file(
    manifest: dict[str, Any], path: Path
) -> dict[str, Any]:
    matches = [
        item
        for item in manifest.get("adapter_files", [])
        if item.get("path") == path.name
    ]
    if len(matches) != 1:
        raise ArtifactError(
            f"selected adapter {path.name} is not uniquely declared by the run"
        )
    return matches[0]


def verify_local_candidate(
    run_directory: Path,
    model_manifest: dict[str, Any],
    models_dir: Path,
) -> tuple[dict[str, Any], dict[str, Any], Path, Path]:
    manifest = load_training_manifest(run_directory)
    if manifest.get("schema_version") != 3:
        raise ArtifactError("Debug reliability-v3 training manifest must use schema 3")
    if not is_reliability_v3(manifest):
        raise ArtifactError(
            "Debug candidate must use the reliability-v3 corpus, prompt, and policy"
        )
    if manifest.get("status") not in ELIGIBLE_LOCAL_STATUSES:
        raise ArtifactError(
            f"Debug candidate local status is not eligible: {manifest.get('status')}"
        )
    if manifest.get("training_numerics", {}).get("status") != "finite":
        raise ArtifactError("Debug candidate training numerics are not finite")

    selected = manifest.get("checkpoint_evaluation", {}).get("selected", {})
    summary = selected.get("summary", {})
    if (
        not isinstance(selected.get("iteration"), int)
        or selected["iteration"] <= 0
        or summary.get("schema_version") != 2
        or summary.get("snapshot_count", 0) < 3
        or summary.get("gold") != "gold_v1.jsonl"
    ):
        raise ArtifactError(
            "Debug candidate lacks a completed three-snapshot gold_v1 selection"
        )

    adapter_directory = Path(manifest.get("outputs", {}).get("adapter", "")).resolve()
    if not adapter_directory.is_dir() or adapter_directory.is_symlink():
        raise ArtifactError(f"Debug adapter directory is missing: {adapter_directory}")
    checkpoint = Path(selected.get("checkpoint_path", "")).resolve()
    if checkpoint.parent != adapter_directory or not checkpoint.is_file():
        raise ArtifactError(
            "selected Debug checkpoint is missing or outside its adapter directory"
        )
    declaration = declared_adapter_file(manifest, checkpoint)
    if (
        declaration.get("sha256") != selected.get("checkpoint_sha256")
        or checkpoint.stat().st_size != declaration.get("size")
        or sha256_file(checkpoint) != declaration.get("sha256")
    ):
        raise ArtifactError("selected Debug checkpoint bytes do not match the manifest")

    adapter_config = adapter_directory / "adapter_config.json"
    config_declaration = declared_adapter_file(manifest, adapter_config)
    if (
        not adapter_config.is_file()
        or adapter_config.stat().st_size != config_declaration.get("size")
        or sha256_file(adapter_config) != config_declaration.get("sha256")
    ):
        raise ArtifactError("Debug adapter configuration does not match the manifest")

    model_key = manifest.get("experiment", {}).get("model_key")
    artifact = next(
        (item for item in model_manifest["models"] if item["key"] == model_key),
        None,
    )
    if artifact is None or artifact.get("derived"):
        raise ArtifactError(f"Debug run references an unsupported base: {model_key}")
    base = local_artifact_path(artifact, models_dir)
    actual_base_sha256 = verify_artifact_tree_at_use(base, artifact)
    if actual_base_sha256 != manifest.get("base", {}).get("directory_sha256"):
        raise ArtifactError("Debug run base-model bytes differ from current verified bytes")
    return manifest, artifact, base, checkpoint


def debug_cache_path(
    fused_cache: Path, manifest: dict[str, Any], selected: dict[str, Any]
) -> Path:
    return fused_cache / (
        f"{manifest['run_id']}-iter-{selected['iteration']:06d}-"
        f"{selected['checkpoint_sha256'][:12]}"
    )


def verify_cached_fusion(
    fused: Path, manifest: dict[str, Any], base_sha256: str
) -> str:
    lock_path = fused / LOCK_FILE
    if not fused.is_dir() or fused.is_symlink() or not lock_path.is_file():
        raise ArtifactError(f"Debug fused cache is incomplete: {fused}")
    lock = json.loads(lock_path.read_text())
    selected = manifest["checkpoint_evaluation"]["selected"]
    expected = {
        "training_run_id": manifest["run_id"],
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "base_directory_sha256": base_sha256,
    }
    for key, value in expected.items():
        if lock.get(key) != value:
            raise ArtifactError(f"Debug fused cache lock disagrees on {key}: {fused}")
    actual = directory_digest(directory_inventory(fused))
    if lock.get("directory_sha256") != actual:
        raise ArtifactError(f"Debug fused cache bytes are stale or modified: {fused}")
    return actual


def fuse_candidate(
    fused: Path,
    manifest: dict[str, Any],
    base: Path,
    checkpoint: Path,
    *,
    runner: Runner = subprocess.run,
) -> str:
    base_sha256 = manifest["base"]["directory_sha256"]
    if fused.exists() or fused.is_symlink():
        return verify_cached_fusion(fused, manifest, base_sha256)

    fused.parent.mkdir(parents=True, exist_ok=True)
    staged = Path(
        tempfile.mkdtemp(prefix=f".{fused.name}.staging-", dir=fused.parent)
    )
    try:
        shutil.rmtree(staged)
        with tempfile.TemporaryDirectory(prefix="creg-debug-adapter-") as value:
            adapter_view = Path(value)
            adapter = Path(manifest["outputs"]["adapter"])
            shutil.copy2(
                adapter / "adapter_config.json", adapter_view / "adapter_config.json"
            )
            shutil.copy2(checkpoint, adapter_view / "adapters.safetensors")
            runner(
                [
                    sys.executable,
                    "-m",
                    "mlx_lm",
                    "fuse",
                    "--model",
                    str(base),
                    "--adapter-path",
                    str(adapter_view),
                    "--save-path",
                    str(staged),
                ],
                cwd=REPO_ROOT / "fine-tuning",
                check=True,
            )
        runner(
            [
                sys.executable,
                "-c",
                (
                    "from mlx_lm import load; "
                    f"load({str(staged)!r}); "
                    "print('Debug fused model load verified')"
                ),
            ],
            cwd=REPO_ROOT / "fine-tuning",
            check=True,
        )
        inventory = directory_inventory(staged)
        digest = directory_digest(inventory)
        selected = manifest["checkpoint_evaluation"]["selected"]
        atomic_write_json(
            staged / LOCK_FILE,
            {
                "schema_version": 1,
                "kind": "creg-debug-fused-model",
                "training_run_id": manifest["run_id"],
                "selected_iteration": selected["iteration"],
                "selected_checkpoint_sha256": selected["checkpoint_sha256"],
                "base_directory_sha256": base_sha256,
                "directory_sha256": digest,
                "all_files": inventory,
                "wandb_receipt_required": False,
            },
        )
        transactionally_replace_directory(staged, fused)
    finally:
        if staged.exists():
            shutil.rmtree(staged)
    return verify_cached_fusion(fused, manifest, base_sha256)


def debug_identity(
    manifest: dict[str, Any], artifact: dict[str, Any]
) -> dict[str, Any]:
    selected = manifest["checkpoint_evaluation"]["selected"]
    return {
        "schema_version": 1,
        "model_key": f"debug-ft-{manifest['run_id']}",
        "base_model_key": artifact["key"],
        "training_run_id": manifest["run_id"],
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "local_evidence_status": manifest["status"],
        "wandb_receipt_required": False,
    }


def debug_quantization(artifact: dict[str, Any]) -> dict[str, Any]:
    if artifact.get("quantization") is not None:
        return copy.deepcopy(artifact["quantization"])
    conversion = artifact.get("conversion") or {}
    if conversion.get("quantize") is True and isinstance(conversion.get("bits"), int):
        return {
            "bits": conversion["bits"],
            "group_size": conversion.get("group_size", 64),
            "mode": conversion.get("mode", "affine"),
        }
    raise ArtifactError(f"Debug base has no declared MLX quantization: {artifact['key']}")


def generated_manifest(
    source: dict[str, Any],
    training: dict[str, Any],
    artifact: dict[str, Any],
    fused_sha256: str,
) -> dict[str, Any]:
    result = copy.deepcopy(source)
    identity = debug_identity(training, artifact)
    synthetic_revision = identity["selected_checkpoint_sha256"][:40]
    repository = f"local-debug/{identity['training_run_id']}"
    result["models"].append(
        {
            "key": identity["model_key"],
            "display_name": (
                f"Experimental {artifact.get('display_name', artifact['key'])} "
                f"iteration {identity['selected_iteration']}"
            ),
            "repository": repository,
            "revision": synthetic_revision,
            "local_directory": identity["model_key"],
            "format": "mlx",
            "derived": True,
            "publication_status": "debug-local-unpublished",
            "snapshot_directory_sha256": fused_sha256,
            "quantization": debug_quantization(artifact),
            "license": artifact["license"],
            "required_files": [],
            "training_run": identity["training_run_id"],
        }
    )
    production = result.get("production") or {}
    result["production_status"] = "debug-candidate"
    result["production"] = {
        "model_key": identity["model_key"],
        "gcd": training["checkpoint_evaluation"]["selected"]["summary"]["gcd"],
        "temperature": 0.0,
        "top_p": 1.0,
        "top_k": 0,
        "max_tokens": int(production.get("max_tokens", 512)),
        "voting": {
            "candidate_count": 1,
            "sample_temperature": 0.0,
            "always_vote": False,
        },
    }
    result["debug_candidate"] = identity
    return result


def copy_verified_file(source: Path, target: Path, declaration: dict[str, Any]) -> None:
    source = source.resolve(strict=True)
    if (
        not source.is_file()
        or source.stat().st_size != declaration["size"]
        or sha256_file(source) != declaration["sha256"]
    ):
        raise ArtifactError(f"Debug distribution file verification failed: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    if (
        target.stat().st_size != declaration["size"]
        or sha256_file(target) != declaration["sha256"]
    ):
        raise ArtifactError(f"Debug distribution copy verification failed: {target}")


def install_debug_distribution_files(
    artifact: dict[str, Any],
    destination: Path,
    *,
    local_files_only: bool,
) -> None:
    for declaration in distribution_files(artifact["license"]):
        target = destination / declaration["path"]
        if target.is_file() and not target.is_symlink():
            if (
                target.stat().st_size != declaration["size"]
                or sha256_file(target) != declaration["sha256"]
            ):
                raise ArtifactError(
                    f"Debug distribution file verification failed: {target}"
                )
            continue
        source = Path(
            hf_hub_download(
                repo_id=declaration["source_repository"],
                filename=declaration["source_path"],
                revision=declaration["source_revision"],
                local_files_only=local_files_only,
            )
        )
        copy_verified_file(source, target, declaration)

    declaration = notice_file(artifact["license"])
    if declaration is not None:
        target = destination / declaration["path"]
        source = REPO_ROOT / declaration["source_path"]
        copy_verified_file(source, target, declaration)


def stage_debug_bundle(
    fused: Path,
    destination: Path,
    artifact: dict[str, Any],
    *,
    local_files_only: bool,
) -> list[dict[str, Any]]:
    # Reject any link before copytree can resolve or preserve it into the app.
    full_directory_inventory(fused)
    shutil.copytree(
        fused,
        destination,
        dirs_exist_ok=True,
        symlinks=True,
        ignore=shutil.ignore_patterns(LOCK_FILE),
    )
    install_debug_distribution_files(
        artifact,
        destination,
        local_files_only=local_files_only,
    )
    return full_directory_inventory(destination)


def materialize_debug_model(
    run_directory: Path,
    *,
    model_manifest_path: Path,
    models_dir: Path,
    fused_cache: Path,
    destination: Path,
    manifest_destination: Path,
    receipt_destination: Path,
    local_files_only: bool = False,
    runner: Runner = subprocess.run,
) -> dict[str, Any]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest_destination.parent.mkdir(parents=True, exist_ok=True)
    receipt_destination.parent.mkdir(parents=True, exist_ok=True)
    source_manifest = load_manifest(model_manifest_path)
    training, artifact, base, checkpoint = verify_local_candidate(
        run_directory, source_manifest, models_dir
    )
    selected = training["checkpoint_evaluation"]["selected"]
    fused = debug_cache_path(fused_cache, training, selected)
    fused_sha256 = fuse_candidate(
        fused, training, base, checkpoint, runner=runner
    )
    manifest = generated_manifest(
        source_manifest, training, artifact, fused_sha256
    )
    debug_artifact = manifest["models"][-1]
    debug_artifact["required_files"] = directory_inventory(fused)

    manifest_stage = manifest_destination.with_name(
        f".{manifest_destination.name}.debug-{uuid.uuid4().hex}"
    )
    receipt_stage = receipt_destination.with_name(
        f".{receipt_destination.name}.debug-{uuid.uuid4().hex}"
    )
    bundle_stage = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}.debug-", dir=destination.parent)
    )
    try:
        manifest_stage.write_bytes(canonical_json(manifest) + b"\n")
        installed = stage_debug_bundle(
            fused,
            bundle_stage,
            debug_artifact,
            local_files_only=local_files_only,
        )
        receipt = {
            "schema_version": 1,
            "model_key": debug_artifact["key"],
            "repository": debug_artifact["repository"],
            "revision": debug_artifact["revision"],
            "directory_sha256": directory_digest(installed),
            "file_count": len(installed),
            "source_manifest_sha256": sha256_file(manifest_stage),
            "debug_candidate": manifest["debug_candidate"],
            "wandb_receipt_required": False,
        }
        atomic_write_json(receipt_stage, receipt)
        transactionally_replace_directory(bundle_stage, destination)
        manifest_stage.replace(manifest_destination)
        receipt_stage.replace(receipt_destination)
    finally:
        if bundle_stage.exists():
            shutil.rmtree(bundle_stage)
        for staged in (manifest_stage, receipt_stage):
            if staged.exists():
                staged.unlink()

    return {
        "status": "debug_model_materialized",
        "training_run_id": training["run_id"],
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "model_key": manifest["debug_candidate"]["model_key"],
        "destination": str(destination),
        "wandb_receipt_required": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument(
        "--training-run",
        help="immutable local training-run directory or run id",
    )
    selection.add_argument(
        "--latest-local-v3",
        action="store_true",
        help="select the newest locally eligible reliability-v3 run",
    )
    parser.add_argument(
        "--training-runs-dir", type=Path, default=DEFAULT_TRAINING_RUNS
    )
    parser.add_argument("--model-manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR)
    parser.add_argument("--fused-cache", type=Path, default=DEFAULT_FUSED_CACHE)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--manifest-destination", type=Path, required=True)
    parser.add_argument("--receipt-destination", type=Path)
    parser.add_argument("--local-files-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    training_runs = args.training_runs_dir.resolve()
    run_directory = (
        select_latest_local_v3(training_runs)
        if args.latest_local_v3
        else resolve_training_run(args.training_run, training_runs)
    )
    destination = args.destination.resolve()
    manifest_destination = args.manifest_destination.resolve()
    receipt_destination = (
        args.receipt_destination.resolve()
        if args.receipt_destination
        else destination.parent / PRODUCTION_RECEIPT_FILE
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = materialize_debug_model(
        run_directory,
        model_manifest_path=args.model_manifest.resolve(),
        models_dir=args.models_dir.resolve(),
        fused_cache=args.fused_cache.resolve(),
        destination=destination,
        manifest_destination=manifest_destination,
        receipt_destination=receipt_destination,
        local_files_only=args.local_files_only,
    )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
