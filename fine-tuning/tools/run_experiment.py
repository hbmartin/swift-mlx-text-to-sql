"""Run one immutable MLX-LM experiment with required online W&B evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

import yaml

from eval.experiment import ExperimentConfig, campaign_tags, immutable_run_id
from eval.file_integrity import transactionally_replace_directory
from eval.prompt_contract import prompt_contract_receipt
from eval.run_artifacts import (
    REPO_ROOT,
    clean_git_provenance,
    create_run_directory,
    hardware_provenance,
    input_hash,
    sha256_file,
    write_json,
)
from eval.wandb_evidence import (
    EvidenceUploader,
    require_wandb_complete,
    required_wandb_environment,
    synchronize_manifest,
)
from tools.evaluate_checkpoints import evaluate_training_checkpoints
from tools.fetch_model import (
    LOCK_FILE,
    directory_digest,
    directory_inventory,
    load_manifest,
    verify_artifact_tree_at_use,
)


MODEL_MANIFEST = REPO_ROOT / "model-manifest.json"
CORPUS_MANIFEST = REPO_ROOT / "fine-tuning" / "config" / "corpus-manifest.json"
BASE_TRAINING_CONFIG = REPO_ROOT / "fine-tuning" / "config" / "qlora.yaml"
TRAINING_RUNS = REPO_ROOT / "eval" / "training-runs"
MODELS_DIR = REPO_ROOT / "models"
CORPUS_GENERATOR = REPO_ROOT / "fine-tuning" / "synth" / "generate_training.py"
UV_LOCK = REPO_ROOT / "fine-tuning" / "uv.lock"
Runner = Callable[..., subprocess.CompletedProcess[Any]]


class CorpusMismatchError(RuntimeError):
    def __init__(self, path: Path) -> None:
        super().__init__(f"regenerated corpus differs byte-for-byte: {path}")


class LayerResolutionError(RuntimeError):
    def __init__(self, config_path: Path) -> None:
        super().__init__(f"cannot resolve all trainable layers from {config_path}")


class MissingVerifiedBaseError(RuntimeError):
    def __init__(self, model_key: str) -> None:
        super().__init__(f"{model_key}: verified base is missing; fetch it first")


class TrainingNumericalIntegrityError(RuntimeError):
    """Raised when MLX reports non-finite or impossible training telemetry."""


TRAIN_REPORT_PATTERN = re.compile(
    r"Iter (?P<iteration>\d+): Train loss (?P<loss>\S+),.*?"
    r"Trained Tokens (?P<trained_tokens>\d+),"
)
VAL_REPORT_PATTERN = re.compile(
    r"Iter (?P<iteration>\d+): Val loss (?P<loss>\S+),"
)


def verify_training_numerics(
    log_path: Path, config: ExperimentConfig
) -> dict[str, Any]:
    """Fail closed on NaN/Inf loss or token counters outside the batch contract."""

    contents = log_path.read_text(errors="replace")
    train_reports = list(TRAIN_REPORT_PATTERN.finditer(contents))
    if not train_reports:
        raise TrainingNumericalIntegrityError(
            "training log contains no parseable train-loss reports"
        )

    previous_tokens = 0
    reports: list[dict[str, Any]] = []
    for match in train_reports:
        iteration = int(match.group("iteration"))
        loss = float(match.group("loss"))
        trained_tokens = int(match.group("trained_tokens"))
        maximum_tokens = iteration * config.batch_size * config.max_seq_length
        if not math.isfinite(loss):
            raise TrainingNumericalIntegrityError(
                f"non-finite train loss at iteration {iteration}: {match.group('loss')}"
            )
        if not previous_tokens < trained_tokens <= maximum_tokens:
            raise TrainingNumericalIntegrityError(
                "impossible trained-token counter at iteration "
                f"{iteration}: {trained_tokens} not in "
                f"({previous_tokens}, {maximum_tokens}]"
            )
        previous_tokens = trained_tokens
        reports.append(
            {
                "iteration": iteration,
                "loss": loss,
                "trained_tokens": trained_tokens,
            }
        )

    if reports[-1]["iteration"] != config.iterations:
        raise TrainingNumericalIntegrityError(
            "training log ended before the configured iteration: "
            f"{reports[-1]['iteration']} != {config.iterations}"
        )

    validations = []
    for match in VAL_REPORT_PATTERN.finditer(contents):
        loss = float(match.group("loss"))
        iteration = int(match.group("iteration"))
        if not math.isfinite(loss):
            raise TrainingNumericalIntegrityError(
                f"non-finite validation loss at iteration {iteration}: "
                f"{match.group('loss')}"
            )
        validations.append({"iteration": iteration, "loss": loss})
    if not validations:
        raise TrainingNumericalIntegrityError(
            "training log contains no parseable validation-loss reports"
        )

    return {
        "status": "finite",
        "train_reports": reports,
        "validation_reports": validations,
        "final_trained_tokens": previous_tokens,
    }


def local_artifact_path(artifact: dict[str, Any], models_dir: Path) -> Path:
    conversion = artifact.get("conversion")
    directory = (
        conversion["output_directory"]
        if conversion is not None
        else artifact["local_directory"]
    )
    return models_dir / directory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-key", required=True)
    parser.add_argument("--seed", type=int, default=424242)
    parser.add_argument("--fine-tune-type", choices=["lora", "dora"], default="lora")
    parser.add_argument(
        "--trainable-layers", choices=["last-16", "all"], default="last-16"
    )
    parser.add_argument("--rank", type=int, default=8)
    parser.add_argument("--scale-ratio", type=float, default=2.5)
    parser.add_argument("--dropout", type=float, default=0.0)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--iterations", type=int, default=600)
    parser.add_argument(
        "--repair-fraction",
        type=float,
        choices=[0.05, 0.10, 0.20],
        default=0.10,
    )
    parser.add_argument("--campaign-id", required=True)
    parser.add_argument(
        "--stage",
        choices=["screening", "promoted", "final"],
        default="screening",
    )
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR)
    parser.add_argument("--training-runs-dir", type=Path, default=TRAINING_RUNS)
    parser.add_argument("--model-manifest", type=Path, default=MODEL_MANIFEST)
    return parser.parse_args()


def verify_regenerated_corpus(
    run_directory: Path,
    *,
    repair_fraction: float = 0.10,
    runner: Runner = subprocess.run,
) -> dict[str, Any]:
    generated = run_directory / "regenerated-corpus"
    runner(
        [
            sys.executable,
            "-m",
            "synth.generate_training",
            "--out-dir",
            str(generated),
            "--repair-fraction",
            str(repair_fraction),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    declaration = json.loads(CORPUS_MANIFEST.read_text())
    variant_key = f"repair-{round(repair_fraction * 100):02d}"
    try:
        variant = declaration["variants"][variant_key]
    except KeyError as error:
        raise CorpusMismatchError(CORPUS_MANIFEST) from error
    comparisons = []
    canonical_files = []
    for file in variant["files"]:
        committed = REPO_ROOT / file["path"]
        regenerated = generated / committed.name
        committed_hash = sha256_file(committed)
        regenerated_hash = sha256_file(regenerated)
        if (
            committed_hash != file["sha256"]
            or regenerated_hash != file["sha256"]
            or committed.read_bytes() != regenerated.read_bytes()
        ):
            raise CorpusMismatchError(committed)
        comparisons.append(
            {
                "committed": input_hash(committed),
                "regenerated": input_hash(regenerated),
                "byte_for_byte_equal": True,
            }
        )
        canonical_files.append({"name": committed.name, "sha256": file["sha256"]})
    variant_payload = {
        "corpus_version": declaration["corpus_version"],
        "repair_fraction": repair_fraction,
        "files": sorted(canonical_files, key=lambda item: item["name"]),
    }
    variant_sha256 = hashlib.sha256(
        json.dumps(
            variant_payload, sort_keys=True, separators=(",", ":")
        ).encode()
    ).hexdigest()
    if variant_sha256 != variant["corpus_sha256"]:
        raise CorpusMismatchError(CORPUS_MANIFEST)
    return {
        "manifest": input_hash(CORPUS_MANIFEST),
        "variant": {
            "key": variant_key,
            "corpus_version": declaration["corpus_version"],
            "repair_fraction": repair_fraction,
            "sha256": variant_sha256,
        },
        "files": comparisons,
    }


def resolve_num_layers(config: ExperimentConfig, base: Path) -> int:
    if config.trainable_layers == "last-16":
        return 16
    model_config = json.loads((base / "config.json").read_text())
    for key in ("num_hidden_layers", "n_layer", "num_layers"):
        value = model_config.get(key)
        if isinstance(value, int) and value > 0:
            return value
    raise LayerResolutionError(base / "config.json")


def write_effective_configuration(
    path: Path,
    *,
    config: ExperimentConfig,
    base: Path,
    corpus_directory: Path,
    adapter: Path,
    project: str,
    metadata: dict[str, Any],
) -> dict[str, Any]:
    effective = yaml.safe_load(BASE_TRAINING_CONFIG.read_text())
    effective.update(
        {
            "model": str(base),
            "data": str(corpus_directory),
            "adapter_path": str(adapter),
            "seed": config.seed,
            "fine_tune_type": config.fine_tune_type,
            "num_layers": resolve_num_layers(config, base),
            "batch_size": config.batch_size,
            "iters": config.iterations,
            "learning_rate": config.learning_rate,
            "grad_accumulation_steps": config.grad_accumulation_steps,
            "grad_checkpoint": config.grad_checkpoint,
            "save_every": config.save_every,
            "max_seq_length": config.max_seq_length,
            "mask_prompt": config.mask_prompt,
            "lr_schedule": None,
            "lora_parameters": {
                "rank": config.rank,
                "dropout": config.dropout,
                "scale": config.effective_scale,
            },
            "report_to": "wandb",
            "project_name": project,
            "creg_experiment": metadata,
        }
    )
    path.write_text(yaml.safe_dump(effective, sort_keys=False))
    return effective


def wandb_run_id() -> str:
    existing = os.environ.get("WANDB_RUN_ID")
    if existing:
        return existing
    import wandb

    return wandb.util.generate_id()


def trainable_parameter_count(checkpoint: Path) -> int:
    """Count adapter tensor elements from the bytes actually checkpointed."""

    import mlx.core as mx

    tensors = mx.load(str(checkpoint))
    return sum(int(tensor.size) for tensor in tensors.values())


def _wandb_subprocess_environment(
    manifest: dict[str, Any],
    wandb_directory: Path,
) -> dict[str, str]:
    environment = os.environ.copy()
    record = manifest["wandb"]
    experiment = manifest["experiment"]
    environment.update(
        {
            "WANDB_MODE": "online",
            "WANDB_ENTITY": record["entity"],
            "WANDB_PROJECT": record["project"],
            "WANDB_RUN_ID": record["run_id"],
            "WANDB_RUN_GROUP": experiment["campaign_id"],
            "WANDB_JOB_TYPE": record["job_type"],
            "WANDB_TAGS": ",".join(record["tags"]),
            "WANDB_RESUME": "allow",
            # Used by W&B integrations that honor the environment. MLX-LM
            # explicitly passes its log_dir, so its adapter_path is a scratch
            # directory that is sanitized after the subprocess exits.
            "WANDB_DIR": str(wandb_directory),
        }
    )
    return environment


def materialize_adapter_artifact(
    scratch: Path,
    destination: Path,
    config: ExperimentConfig,
) -> list[dict[str, Any]]:
    """Copy only exact MLX adapter payload files out of W&B scratch state."""
    scratch_metadata = scratch.lstat()
    if stat.S_ISLNK(scratch_metadata.st_mode) or not stat.S_ISDIR(
        scratch_metadata.st_mode
    ):
        raise RuntimeError(f"MLX adapter scratch is not a real directory: {scratch}")
    expected_names = {
        "adapter_config.json",
        "adapters.safetensors",
        *{
            f"{iteration:07d}_adapters.safetensors"
            for iteration in range(
                config.save_every, config.iterations + 1, config.save_every
            )
        },
    }
    entries = {path.name: path for path in scratch.iterdir()}
    missing = sorted(expected_names - set(entries))
    extras = sorted(set(entries) - expected_names - {"wandb"})
    if missing or extras:
        raise RuntimeError(
            "unexpected MLX adapter scratch inventory: "
            f"missing={missing}, extras={extras}"
        )
    if (wandb_directory := entries.get("wandb")) is not None:
        metadata = wandb_directory.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError(
                f"W&B scratch transport is not a real directory: {wandb_directory}"
            )

    source_inventory = sorted(
        (
            {
                "path": name,
                "size": entries[name].lstat().st_size,
                "sha256": sha256_file(entries[name]),
            }
            for name in expected_names
        ),
        key=lambda item: item["path"],
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}.staging-", dir=destination.parent)
    )
    try:
        for item in source_inventory:
            shutil.copy2(entries[item["path"]], staged / item["path"])
        staged_inventory = directory_inventory(staged)
        if staged_inventory != source_inventory:
            raise RuntimeError("staged adapter bytes differ from MLX output")
        transactionally_replace_directory(staged, destination)
    finally:
        if staged.exists():
            shutil.rmtree(staged)
    installed_inventory = directory_inventory(destination)
    if installed_inventory != source_inventory:
        raise RuntimeError("installed adapter bytes differ from verified staging")
    # This directory contains only duplicate payload bytes and W&B's mutable
    # local transport (including convenience symlinks), never canonical
    # evidence. The clean destination above is the sole adapter artifact.
    shutil.rmtree(scratch)
    return installed_inventory


def _fuse_selected_checkpoint(
    manifest_path: Path,
    artifact: dict[str, Any],
    base: Path,
    *,
    runner: Runner = subprocess.run,
) -> None:
    manifest = json.loads(manifest_path.read_text())
    require_wandb_complete(manifest, operation="checkpoint fusion")
    selected = manifest["checkpoint_evaluation"]["selected"]
    adapter = Path(manifest["outputs"]["adapter"])
    fused = Path(manifest["outputs"]["fused"])
    if fused.exists():
        raise RuntimeError(f"refusing to overwrite fused output: {fused}")

    with tempfile.TemporaryDirectory(prefix="creg-fuse-adapter-") as value:
        adapter_view = Path(value)
        shutil.copy2(
            adapter / "adapter_config.json", adapter_view / "adapter_config.json"
        )
        shutil.copy2(
            Path(selected["checkpoint_path"]),
            adapter_view / "adapters.safetensors",
        )
        command = [
            sys.executable,
            "-m",
            "mlx_lm",
            "fuse",
            "--model",
            str(base),
            "--adapter-path",
            str(adapter_view),
            "--save-path",
            str(fused),
        ]
        runner(command, cwd=REPO_ROOT / "fine-tuning", check=True)

    runner(
        [
            sys.executable,
            "-c",
            (
                "from mlx_lm import load; "
                f"load({str(fused)!r}); "
                "print('fused model load verified')"
            ),
        ],
        cwd=REPO_ROOT / "fine-tuning",
        check=True,
    )
    inventory = directory_inventory(fused)
    training_provenance = {
        "run_id": manifest["run_id"],
        "seed": manifest["experiment"]["seed"],
        "configuration_sha256": manifest["experiment"]["configuration_sha256"],
        "selected_checkpoint_iteration": selected["iteration"],
        "selected_checkpoint_sha256": selected["checkpoint_sha256"],
        "base_repository": artifact["repository"],
        "base_revision": artifact["revision"],
        "base_directory_sha256": manifest["base"]["directory_sha256"],
        "code_commit": manifest["git"]["commit"],
        "code_dirty": manifest["git"]["dirty"],
        "code_inputs": manifest["inputs"],
        "configuration": manifest["configuration"]["effective"],
        "corpus_manifest": manifest["corpus"]["manifest"],
        "adapter_files": manifest["adapter_files"],
        "training_log_sha256": manifest["training_log"]["sha256"],
        "canonical_evidence_sha256": manifest["wandb"]["receipt"][
            "canonical_evidence_sha256"
        ],
        "wandb": manifest["wandb"]["receipt"],
    }
    lock = {
        "schema_version": 1,
        "key": f"ft-{manifest['run_id']}",
        "repository": None,
        "revision": None,
        "format": "mlx",
        "quantization": {"bits": 4, "group_size": 64, "mode": "affine"},
        "all_files": inventory,
        "verified_files": inventory,
        "directory_sha256": directory_digest(inventory),
        "training_provenance": training_provenance,
    }
    write_json(fused / LOCK_FILE, lock)
    manifest["fused_reference"] = {
        "repository": None,
        "revision": None,
        "directory_sha256": lock["directory_sha256"],
        "lock_path": str((fused / LOCK_FILE).resolve()),
        "lock_sha256": sha256_file(fused / LOCK_FILE),
    }
    manifest["candidate_manifest_entry"] = {
        "key": lock["key"],
        "display_name": fused.name,
        "repository": None,
        "revision": None,
        "local_directory": fused.name,
        "format": "mlx",
        "derived": True,
        "experiment_authority": "wandb",
        "publication_status": "local-unpublished",
        "training_run": manifest["run_id"],
        "base_key": artifact["key"],
        "snapshot_directory_sha256": lock["directory_sha256"],
        "quantization": lock["quantization"],
        "license": artifact["license"],
        "required_files": inventory,
        "training_provenance": training_provenance,
    }
    manifest["status"] = "local_complete"
    write_json(manifest_path, manifest)


def finalize_synchronized_manifest(manifest_path: Path) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text())
    require_wandb_complete(manifest, operation="experiment finalization")
    if manifest.get("experiment", {}).get("stage") != "screening":
        if not manifest.get("fused_reference"):
            raise RuntimeError("promoted/final experiment is not fused")
        manifest["candidate_manifest_entry"]["training_provenance"]["wandb"] = manifest[
            "wandb"
        ]["receipt"]
    manifest["status"] = "complete"
    manifest["completed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    write_json(manifest_path, manifest)
    return manifest


def run_experiment(
    config: ExperimentConfig,
    *,
    models_dir: Path = MODELS_DIR,
    training_runs_dir: Path = TRAINING_RUNS,
    model_manifest_path: Path = MODEL_MANIFEST,
    runner: Runner = subprocess.run,
    uploader: EvidenceUploader | None = None,
    run_id_factory: Callable[[], str] = wandb_run_id,
) -> Path:
    authority = required_wandb_environment()
    model_manifest_path = model_manifest_path.resolve()
    model_manifest = load_manifest(model_manifest_path)
    artifacts = {model["key"]: model for model in model_manifest["models"]}
    artifact = artifacts.get(config.model_key)
    if artifact is None or artifact.get("derived"):
        raise RuntimeError(f"{config.model_key} is not a supported base artifact")
    models_dir = models_dir.resolve()
    base = local_artifact_path(artifact, models_dir)
    if not (base / LOCK_FILE).is_file():
        raise MissingVerifiedBaseError(config.model_key)
    base_sha256 = verify_artifact_tree_at_use(base, artifact)

    # Repository provenance is a precondition. Check it before reserving the
    # immutable run directory or regenerating a corpus into that directory.
    git = clean_git_provenance()
    wb_run_id = run_id_factory()
    run_id = immutable_run_id(config, wb_run_id)
    training_runs_dir = training_runs_dir.resolve()
    run_directory = training_runs_dir / run_id
    adapter = models_dir / "adapters" / config.campaign_id / run_id
    scratch_adapter = run_directory / "mlx-adapter-scratch"
    fused = models_dir / "fused" / (f"{run_id}-iter-{config.iterations:06d}")
    if run_directory.exists() or run_directory.is_symlink():
        raise RuntimeError(f"refusing to overwrite training run {run_directory}")
    if adapter.exists() or fused.exists():
        raise RuntimeError(f"refusing to overwrite output for {run_id}")
    run_directory = create_run_directory(training_runs_dir, run_id)

    corpus = verify_regenerated_corpus(
        run_directory,
        repair_fraction=config.repair_fraction,
        runner=runner,
    )
    experiment = config.manifest_payload()
    prompt_contract = prompt_contract_receipt()
    tags = campaign_tags(
        config,
        corpus_sha256=corpus["variant"]["sha256"],
        git_commit=git["commit"],
        status="running",
        prompt_version=prompt_contract["prompt_version"],
        policy_version=prompt_contract["policy_version"],
        corpus_version=corpus["variant"]["corpus_version"],
    )
    effective_config_path = run_directory / "effective-config.yaml"
    effective = write_effective_configuration(
        effective_config_path,
        config=config,
        base=base,
        corpus_directory=run_directory / "regenerated-corpus",
        adapter=scratch_adapter,
        project=authority["project"],
        metadata={
            **experiment,
            "run_id": run_id,
            "base_directory_sha256": base_sha256,
            "corpus_manifest_sha256": corpus["manifest"]["sha256"],
            "corpus_variant_sha256": corpus["variant"]["sha256"],
            "corpus_version": corpus["variant"]["corpus_version"],
            "repair_fraction": config.repair_fraction,
            "git_commit": git["commit"],
            **prompt_contract,
        },
    )
    command = [
        sys.executable,
        "-m",
        "mlx_lm",
        "lora",
        "--config",
        str(effective_config_path),
    ]
    manifest = {
        "schema_version": 3,
        "run_id": run_id,
        "status": "training",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "command": command,
        "experiment": experiment,
        "prompt_contract": prompt_contract,
        "git": git,
        "hardware": hardware_provenance(),
        "base": {
            "key": artifact["key"],
            "repository": artifact["repository"],
            "revision": artifact["revision"],
            "directory_sha256": base_sha256,
            "lock": input_hash(base / LOCK_FILE),
        },
        "configuration": {
            **input_hash(effective_config_path),
            "effective": input_hash(effective_config_path),
            "base_template": input_hash(BASE_TRAINING_CONFIG),
            "values": effective,
        },
        "corpus": corpus,
        "inputs": {
            "experiment_runner": input_hash(Path(__file__)),
            "training_runner": input_hash(Path(__file__)),
            "corpus_generator": input_hash(CORPUS_GENERATOR),
            "model_manifest": input_hash(model_manifest_path),
            "uv_lock": input_hash(UV_LOCK),
        },
        "outputs": {
            "adapter": str(adapter),
            "fused": str(fused) if config.stage != "screening" else None,
        },
        "wandb": {
            "required": True,
            "mode": "online",
            "entity": authority["entity"],
            "project": authority["project"],
            "run_id": wb_run_id,
            "group": config.campaign_id,
            "job_type": (
                "confirmation" if config.stage == "promoted" else config.stage
            ),
            "tags": tags,
        },
    }
    manifest_path = run_directory / "manifest.json"
    write_json(manifest_path, manifest)
    log_path = run_directory / "training.log"
    training_started = time.perf_counter()
    try:
        with log_path.open("xb") as log:
            completed = runner(
                command,
                cwd=REPO_ROOT / "fine-tuning",
                stdout=log,
                stderr=subprocess.STDOUT,
                env=_wandb_subprocess_environment(manifest, run_directory),
            )
    except BaseException as error:
        interrupted = isinstance(error, (KeyboardInterrupt, SystemExit))
        manifest = json.loads(manifest_path.read_text())
        manifest["durations"] = {
            "training": time.perf_counter() - training_started,
        }
        if log_path.is_file():
            manifest["training_log"] = input_hash(log_path)
        manifest["status"] = (
            "training_interrupted" if interrupted else "training_failed"
        )
        manifest["training_failure"] = {
            "type": type(error).__name__,
            "message": str(error),
        }
        write_json(manifest_path, manifest)
        raise
    manifest = json.loads(manifest_path.read_text())
    manifest["durations"] = {
        "training": time.perf_counter() - training_started,
    }
    manifest["training_log"] = input_hash(log_path)
    if completed.returncode:
        manifest["status"] = "training_failed"
        write_json(manifest_path, manifest)
        raise RuntimeError(f"training failed; see {log_path}")
    try:
        manifest["training_numerics"] = verify_training_numerics(log_path, config)
    except TrainingNumericalIntegrityError as error:
        manifest["status"] = "training_failed"
        manifest["training_failure"] = {
            "type": type(error).__name__,
            "message": str(error),
        }
        write_json(manifest_path, manifest)
        raise
    manifest["adapter_files"] = materialize_adapter_artifact(
        scratch_adapter, adapter, config
    )
    manifest["trainable_parameter_count"] = trainable_parameter_count(
        adapter / "adapters.safetensors"
    )
    manifest["status"] = "training_complete"
    write_json(manifest_path, manifest)

    evaluate_training_checkpoints(
        manifest_path,
        model_manifest=model_manifest_path,
        models_dir=models_dir,
        runner=runner,
    )
    synchronize_manifest(manifest_path, uploader=uploader)
    if config.stage == "screening":
        finalize_synchronized_manifest(manifest_path)
        return run_directory

    _fuse_selected_checkpoint(
        manifest_path,
        artifact,
        base,
        runner=runner,
    )
    # The second synchronization records the fused model reference and its
    # repository hashes. The first successful receipt is what authorizes fuse.
    synchronize_manifest(manifest_path, uploader=uploader)
    finalize_synchronized_manifest(manifest_path)
    return run_directory


def main() -> None:
    args = parse_args()
    try:
        config = ExperimentConfig(
            model_key=args.model_key,
            seed=args.seed,
            fine_tune_type=args.fine_tune_type,
            trainable_layers=args.trainable_layers,
            rank=args.rank,
            scale_ratio=args.scale_ratio,
            dropout=args.dropout,
            learning_rate=args.learning_rate,
            iterations=args.iterations,
            campaign_id=args.campaign_id,
            stage=args.stage,
            repair_fraction=args.repair_fraction,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    run_directory = run_experiment(
        config,
        models_dir=args.models_dir,
        training_runs_dir=args.training_runs_dir,
        model_manifest_path=args.model_manifest,
    )
    print(json.dumps({"run_directory": str(run_directory)}, indent=2))


if __name__ == "__main__":
    main()
