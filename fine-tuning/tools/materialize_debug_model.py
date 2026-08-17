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
    DEVICE_RUNTIME_COMPILED_QWEN2_MLP_FUSION,
    DEVICE_RUNTIME_COMPILED_QWEN2_QKV_VERIFICATION_FUSION,
    DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP,
    DEVICE_RUNTIME_VERIFICATION_MLP_ADDITIONAL_CONFIDENCE_SKIPS,
    DEVICE_RUNTIME_VERIFICATION_MLP_LONG_BATCH_EXTRA_SKIP_LAYERS,
    DEVICE_RUNTIME_VERIFICATION_MLP_SKIP_LAYERS,
    DEVICE_RUNTIME_GCD,
    DEVICE_RUNTIME_MAX_TOKENS,
    DEVICE_RUNTIME_METAL_COMMAND_BUFFER_LIMIT_MB,
    DEVICE_RUNTIME_QUESTION_AWARE_OUTPUT_HEAD,
    DEVICE_RUNTIME_SPECULATIVE_DECODING,
    LOCK_FILE,
    MULTI_CONFIDENCE_MLP_PRUNED_DEVICE_RUNTIME_POLICY_VERSION,
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
DEVICE_QUANTIZATION_POLICY_VERSION = "iphone-q4-g128-v2"
DEVICE_QUANTIZATION = {"bits": 4, "group_size": 128, "mode": "affine"}
EVALUATED_QWEN_RUN = (
    "qwen25-coder-3b-"
    "73cb7525c61bc76c76d880076d56d39e0f25cd1675f21a01c28ae2b560838500-"
    "seed-424242-wb-0qvg7e4k"
)
EVALUATED_DEVICE_ARTIFACTS = {
    EVALUATED_QWEN_RUN: {
        "selected_iteration": 600,
        "selected_checkpoint_sha256": (
            "6dddb9955037c294e37b29526e6a6b3bbb6b489eb19c251931bfa87106616baa"
        ),
        "source_fused_directory_sha256": (
            "b839a6bcadfe56a6c62935017beedcb7bfc0c1d91cb121340aa38c4424a9afa4"
        ),
        "device_directory_sha256": (
            "6a99ed1b3126390b15a82c06cdb1aed7f12bbbc06cb51abd1eee0c4e8ee2aab6"
        ),
    }
}
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


def debug_source_cache_path(
    fused_cache: Path, manifest: dict[str, Any], selected: dict[str, Any]
) -> Path:
    return fused_cache / (
        f"{manifest['run_id']}-iter-{selected['iteration']:06d}-"
        f"{selected['checkpoint_sha256'][:12]}"
    )


def debug_cache_path(
    fused_cache: Path, manifest: dict[str, Any], selected: dict[str, Any]
) -> Path:
    quantization = DEVICE_QUANTIZATION
    return fused_cache / (
        f"{manifest['run_id']}-iter-{selected['iteration']:06d}-"
        f"{selected['checkpoint_sha256'][:12]}-q{quantization['bits']}-"
        f"g{quantization['group_size']}-{quantization['mode']}-v2"
    )


def evaluated_device_artifact(manifest: dict[str, Any]) -> dict[str, Any] | None:
    evidence = EVALUATED_DEVICE_ARTIFACTS.get(manifest["run_id"])
    if evidence is None:
        return None
    selected = manifest["checkpoint_evaluation"]["selected"]
    if (
        selected["iteration"] != evidence["selected_iteration"]
        or selected["checkpoint_sha256"]
        != evidence["selected_checkpoint_sha256"]
    ):
        raise ArtifactError(
            "Evaluated Debug device artifact disagrees with selected checkpoint"
        )
    return evidence


def verify_cached_source_fusion(
    fused: Path, manifest: dict[str, Any], base_sha256: str
) -> str:
    lock_path = fused / LOCK_FILE
    if not fused.is_dir() or fused.is_symlink() or not lock_path.is_file():
        raise ArtifactError(f"Debug source fusion is incomplete: {fused}")
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
            raise ArtifactError(
                f"Debug source fusion lock disagrees on {key}: {fused}"
            )
    actual = directory_digest(directory_inventory(fused))
    if lock.get("directory_sha256") != actual:
        raise ArtifactError(f"Debug source fusion bytes are stale: {fused}")
    evidence = evaluated_device_artifact(manifest)
    if (
        evidence is not None
        and evidence["source_fused_directory_sha256"] != actual
    ):
        raise ArtifactError(
            "Debug source fusion differs from the latency/accuracy-evaluated bytes"
        )
    return actual


def verify_cached_fusion(
    fused: Path,
    manifest: dict[str, Any],
    base_sha256: str,
    source_fused_sha256: str,
) -> str:
    lock_path = fused / LOCK_FILE
    if not fused.is_dir() or fused.is_symlink() or not lock_path.is_file():
        raise ArtifactError(f"Debug device cache is incomplete: {fused}")
    lock = json.loads(lock_path.read_text())
    selected = manifest["checkpoint_evaluation"]["selected"]
    expected = {
        "training_run_id": manifest["run_id"],
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "base_directory_sha256": base_sha256,
        "source_fused_directory_sha256": source_fused_sha256,
        "device_quantization_policy_version": DEVICE_QUANTIZATION_POLICY_VERSION,
        "device_quantization": DEVICE_QUANTIZATION,
    }
    for key, value in expected.items():
        if lock.get(key) != value:
            raise ArtifactError(f"Debug device cache lock disagrees on {key}: {fused}")
    actual = directory_digest(directory_inventory(fused))
    if lock.get("directory_sha256") != actual:
        raise ArtifactError(f"Debug device cache bytes are stale: {fused}")
    evidence = evaluated_device_artifact(manifest)
    if evidence is not None and evidence["device_directory_sha256"] != actual:
        raise ArtifactError(
            "Debug device cache differs from the latency/accuracy-evaluated bytes"
        )
    return actual


def fuse_source_candidate(
    fused: Path,
    manifest: dict[str, Any],
    base: Path,
    checkpoint: Path,
    *,
    runner: Runner = subprocess.run,
) -> str:
    base_sha256 = manifest["base"]["directory_sha256"]
    if fused.exists() or fused.is_symlink():
        return verify_cached_source_fusion(fused, manifest, base_sha256)

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
                    "print('Debug source fusion load verified')"
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
    return verify_cached_source_fusion(fused, manifest, base_sha256)


def requantize_candidate(
    fused: Path,
    source_fused: Path,
    source_fused_sha256: str,
    manifest: dict[str, Any],
    *,
    runner: Runner = subprocess.run,
) -> str:
    base_sha256 = manifest["base"]["directory_sha256"]
    if fused.exists() or fused.is_symlink():
        return verify_cached_fusion(
            fused, manifest, base_sha256, source_fused_sha256
        )

    fused.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(
        tempfile.mkdtemp(prefix=f".{fused.name}.workspace-", dir=fused.parent)
    )
    optimized = fused.parent / f".{fused.name}.staging-{uuid.uuid4().hex}"
    try:
        dequantized = workspace / "dequantized"
        # Preserve the exact evaluated source fusion. Direct BF16 fusion and
        # re-fusion under a changed toolchain both altered SQL accuracy.
        runner(
            [
                sys.executable,
                "-m",
                "mlx_lm",
                "convert",
                "--hf-path",
                str(source_fused),
                "--mlx-path",
                str(dequantized),
                "--dequantize",
            ],
            cwd=REPO_ROOT / "fine-tuning",
            check=True,
        )
        runner(
            [
                sys.executable,
                "-m",
                "mlx_lm",
                "convert",
                "--hf-path",
                str(dequantized),
                "--mlx-path",
                str(optimized),
                "--quantize",
                "--q-bits",
                str(DEVICE_QUANTIZATION["bits"]),
                "--q-group-size",
                str(DEVICE_QUANTIZATION["group_size"]),
                "--q-mode",
                DEVICE_QUANTIZATION["mode"],
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
                    f"load({str(optimized)!r}); "
                    "print('Debug device-quantized model load verified')"
                ),
            ],
            cwd=REPO_ROOT / "fine-tuning",
            check=True,
        )
        inventory = directory_inventory(optimized)
        digest = directory_digest(inventory)
        selected = manifest["checkpoint_evaluation"]["selected"]
        atomic_write_json(
            optimized / LOCK_FILE,
            {
                "schema_version": 1,
                "kind": "creg-debug-device-model",
                "training_run_id": manifest["run_id"],
                "selected_iteration": selected["iteration"],
                "selected_checkpoint_sha256": selected["checkpoint_sha256"],
                "base_directory_sha256": base_sha256,
                "source_fused_directory_sha256": source_fused_sha256,
                "device_quantization_policy_version": (
                    DEVICE_QUANTIZATION_POLICY_VERSION
                ),
                "device_quantization": DEVICE_QUANTIZATION,
                "directory_sha256": digest,
                "all_files": inventory,
                "wandb_receipt_required": False,
            },
        )
        transactionally_replace_directory(optimized, fused)
    finally:
        if optimized.exists():
            shutil.rmtree(optimized)
        if workspace.exists():
            shutil.rmtree(workspace)
    return verify_cached_fusion(
        fused, manifest, base_sha256, source_fused_sha256
    )


def debug_identity(
    manifest: dict[str, Any], artifact: dict[str, Any]
) -> dict[str, Any]:
    selected = manifest["checkpoint_evaluation"]["selected"]
    return {
        "schema_version": 1,
        "model_key": f"debug-ft-{manifest['run_id']}-q4-g128-v2",
        "base_model_key": artifact["key"],
        "training_run_id": manifest["run_id"],
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "device_quantization_policy_version": DEVICE_QUANTIZATION_POLICY_VERSION,
        "device_quantization": copy.deepcopy(DEVICE_QUANTIZATION),
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


def validate_device_requantization(artifact: dict[str, Any]) -> dict[str, Any]:
    source = debug_quantization(artifact)
    if source.get("bits") != 4 or source.get("mode", "affine") != "affine":
        raise ArtifactError(
            "Debug device requantization requires a 4-bit affine training base"
        )
    return source


def generated_manifest(
    source: dict[str, Any],
    training: dict[str, Any],
    artifact: dict[str, Any],
    fused_sha256: str,
    source_fused_sha256: str,
) -> dict[str, Any]:
    result = copy.deepcopy(source)
    identity = debug_identity(training, artifact)
    source_quantization = validate_device_requantization(artifact)
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
            "quantization": copy.deepcopy(DEVICE_QUANTIZATION),
            "derivation": {
                "policy_version": DEVICE_QUANTIZATION_POLICY_VERSION,
                "source_quantization": source_quantization,
                "source_fused_directory_sha256": source_fused_sha256,
                "pipeline": "fuse-dequantize-requantize-v1",
            },
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
        "device_runtime": {
            "policy_version": (
                MULTI_CONFIDENCE_MLP_PRUNED_DEVICE_RUNTIME_POLICY_VERSION
            ),
            "gcd": DEVICE_RUNTIME_GCD,
            "max_tokens": DEVICE_RUNTIME_MAX_TOKENS,
            "metal_command_buffer_limit_mb": (
                DEVICE_RUNTIME_METAL_COMMAND_BUFFER_LIMIT_MB
            ),
            "compiled_qwen2_mlp_fusion": (
                DEVICE_RUNTIME_COMPILED_QWEN2_MLP_FUSION
            ),
            "compiled_qwen2_qkv_verification_fusion": (
                DEVICE_RUNTIME_COMPILED_QWEN2_QKV_VERIFICATION_FUSION
            ),
            "verification_mlp_skip_layers": copy.deepcopy(
                DEVICE_RUNTIME_VERIFICATION_MLP_SKIP_LAYERS
            ),
            "verification_mlp_long_batch_extra_skip_layers": copy.deepcopy(
                DEVICE_RUNTIME_VERIFICATION_MLP_LONG_BATCH_EXTRA_SKIP_LAYERS
            ),
            "verification_mlp_confidence_skip": copy.deepcopy(
                DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP
            ),
            "verification_mlp_additional_confidence_skips": copy.deepcopy(
                DEVICE_RUNTIME_VERIFICATION_MLP_ADDITIONAL_CONFIDENCE_SKIPS
            ),
            "question_aware_output_head": (
                DEVICE_RUNTIME_QUESTION_AWARE_OUTPUT_HEAD
            ),
            "speculative_decoding": copy.deepcopy(
                DEVICE_RUNTIME_SPECULATIVE_DECODING
            ),
        },
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
    validate_device_requantization(artifact)
    selected = training["checkpoint_evaluation"]["selected"]
    source_fused = debug_source_cache_path(fused_cache, training, selected)
    source_fused_sha256 = fuse_source_candidate(
        source_fused, training, base, checkpoint, runner=runner
    )
    fused = debug_cache_path(fused_cache, training, selected)
    fused_sha256 = requantize_candidate(
        fused,
        source_fused,
        source_fused_sha256,
        training,
        runner=runner,
    )
    manifest = generated_manifest(
        source_manifest,
        training,
        artifact,
        fused_sha256,
        source_fused_sha256,
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


def preflight_debug_candidate(
    run_directory: Path,
    *,
    model_manifest_path: Path,
    models_dir: Path,
    fused_cache: Path,
) -> dict[str, Any]:
    """Resolve and fully validate a candidate without materializing it."""
    source_manifest = load_manifest(model_manifest_path)
    training, artifact, base, checkpoint = verify_local_candidate(
        run_directory, source_manifest, models_dir
    )
    validate_device_requantization(artifact)
    selected = training["checkpoint_evaluation"]["selected"]
    return {
        "status": "debug_candidate_preflight_complete",
        "training_run_id": training["run_id"],
        "training_run_directory": str(run_directory),
        "adapter_directory": str(checkpoint.parent),
        "checkpoint": str(checkpoint),
        "base_model_key": artifact["key"],
        "base_model_directory": str(base),
        "selected_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "fused_cache": str(fused_cache),
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
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--manifest-destination", type=Path)
    parser.add_argument("--receipt-destination", type=Path)
    parser.add_argument("--local-files-only", action="store_true")
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="resolve and validate the selected candidate without materializing it",
    )
    args = parser.parse_args()
    if not args.preflight:
        if args.destination is None:
            parser.error("--destination is required unless --preflight is used")
        if args.manifest_destination is None:
            parser.error(
                "--manifest-destination is required unless --preflight is used"
            )
    return args


def main() -> None:
    args = parse_args()
    training_runs = args.training_runs_dir.resolve()
    run_directory = (
        select_latest_local_v3(training_runs)
        if args.latest_local_v3
        else resolve_training_run(args.training_run, training_runs)
    )
    if args.preflight:
        result = preflight_debug_candidate(
            run_directory,
            model_manifest_path=args.model_manifest.resolve(),
            models_dir=args.models_dir.resolve(),
            fused_cache=args.fused_cache.resolve(),
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return

    assert args.destination is not None
    assert args.manifest_destination is not None
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
