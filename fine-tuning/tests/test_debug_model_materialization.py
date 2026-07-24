import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from tools.fetch_model import LOCK_FILE, directory_digest, directory_inventory
from tools.materialize_debug_model import (
    ArtifactError,
    materialize_debug_model,
    select_latest_local_v3,
)


def record(path: Path) -> dict:
    return {
        "path": path.name,
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def fixture(tmp_path: Path) -> dict[str, Path]:
    models = tmp_path / "models"
    base = models / "base"
    base.mkdir(parents=True)
    (base / "config.json").write_text('{"model_type":"test"}\n')
    (base / "model.safetensors").write_bytes(b"base-weights")
    base_inventory = directory_inventory(base)
    base_sha256 = directory_digest(base_inventory)
    (base / LOCK_FILE).write_text(
        json.dumps({"directory_sha256": base_sha256})
    )

    artifact = {
        "key": "base",
        "display_name": "Test Base",
        "repository": "owner/base",
        "revision": "a" * 40,
        "local_directory": "base",
        "format": "mlx",
        "snapshot_directory_sha256": base_sha256,
        "quantization": {"bits": 4, "group_size": 64, "mode": "affine"},
        "license": {
            "id": "apache-2.0",
            "commercial_use": True,
            "url": "https://example.com/license",
        },
        "required_files": base_inventory,
    }
    model_manifest = tmp_path / "model-manifest.json"
    model_manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "models": [artifact],
                "production_status": "verified",
                "production": {
                    "model_key": "base",
                    "gcd": "on",
                    "temperature": 0.0,
                    "top_p": 1.0,
                    "top_k": 0,
                    "max_tokens": 512,
                    "voting": {
                        "candidate_count": 1,
                        "sample_temperature": 0.0,
                        "always_vote": False,
                    },
                },
            }
        )
    )

    run = tmp_path / "training-runs" / "run-new"
    adapter = tmp_path / "adapters" / "run-new"
    run.mkdir(parents=True)
    adapter.mkdir(parents=True)
    adapter_config = adapter / "adapter_config.json"
    checkpoint = adapter / "0000600_adapters.safetensors"
    adapter_config.write_text('{"rank":8}\n')
    checkpoint.write_bytes(b"adapter-weights")
    run_manifest = {
        "schema_version": 3,
        "run_id": "run-new",
        "started_at": "2026-07-24T02:09:39Z",
        "status": "awaiting_wandb",
        "experiment": {
            "model_key": "base",
        },
        "corpus": {"variant": {"corpus_version": "reliability-v3"}},
        "prompt_contract": {
            "prompt_version": "reliability-v3",
            "policy_version": "bounded-three-generation-v1",
        },
        "base": {"key": "base", "directory_sha256": base_sha256},
        "training_numerics": {"status": "finite"},
        "outputs": {"adapter": str(adapter), "fused": None},
        "adapter_files": [record(adapter_config), record(checkpoint)],
        "checkpoint_evaluation": {
            "selected": {
                "iteration": 600,
                "checkpoint_path": str(checkpoint),
                "checkpoint_sha256": record(checkpoint)["sha256"],
                "summary": {
                    "schema_version": 2,
                    "snapshot_count": 3,
                    "gold": "gold_v1.jsonl",
                    "gcd": "on",
                },
            }
        },
        # The Debug materializer must neither require nor manufacture this receipt.
        "wandb": {
            "required": True,
            "last_error": {"type": "BrokenPipeError", "message": "broken pipe"},
        },
    }
    (run / "manifest.json").write_text(json.dumps(run_manifest))
    return {
        "models": models,
        "base": base,
        "manifest": model_manifest,
        "run": run,
        "training_runs": run.parent,
    }


def fake_fusion_runner(command, *, cwd, check):
    assert check is True
    if "fuse" in command:
        base = Path(command[command.index("--model") + 1])
        destination = Path(command[command.index("--save-path") + 1])
        shutil.copytree(base, destination, ignore=shutil.ignore_patterns(LOCK_FILE))
    return subprocess.CompletedProcess(command, 0)


def test_debug_materialization_accepts_local_evidence_without_wandb_receipt(tmp_path):
    paths = fixture(tmp_path)
    resources = tmp_path / "Build" / "CREG.app"
    result = materialize_debug_model(
        paths["run"],
        model_manifest_path=paths["manifest"],
        models_dir=paths["models"],
        fused_cache=paths["models"] / "debug-fused",
        destination=resources / "SQLModel",
        manifest_destination=resources / "model-manifest.json",
        receipt_destination=resources / "production-model-receipt.json",
        runner=fake_fusion_runner,
    )

    assert result["wandb_receipt_required"] is False
    generated = json.loads((resources / "model-manifest.json").read_text())
    assert generated["production_status"] == "debug-candidate"
    assert generated["debug_candidate"]["training_run_id"] == "run-new"
    assert generated["debug_candidate"]["selected_iteration"] == 600
    assert generated["debug_candidate"]["wandb_receipt_required"] is False
    assert generated["production"]["voting"]["candidate_count"] == 1
    receipt = json.loads((resources / "production-model-receipt.json").read_text())
    assert receipt["debug_candidate"]["training_run_id"] == "run-new"
    assert receipt["wandb_receipt_required"] is False
    assert (resources / "SQLModel" / "model.safetensors").is_file()


def test_latest_local_v3_ignores_a_newer_incomplete_run(tmp_path):
    paths = fixture(tmp_path)
    incomplete = paths["training_runs"] / "run-incomplete"
    incomplete.mkdir()
    manifest = json.loads((paths["run"] / "manifest.json").read_text())
    manifest.update(
        run_id="run-incomplete",
        started_at="2026-07-25T00:00:00Z",
        status="training",
    )
    (incomplete / "manifest.json").write_text(json.dumps(manifest))

    assert select_latest_local_v3(paths["training_runs"]) == paths["run"]


def test_debug_materialization_rejects_nonfinite_training(tmp_path):
    paths = fixture(tmp_path)
    manifest_path = paths["run"] / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["training_numerics"]["status"] = "invalid"
    manifest_path.write_text(json.dumps(manifest))

    with pytest.raises(ArtifactError, match="numerics are not finite"):
        materialize_debug_model(
            paths["run"],
            model_manifest_path=paths["manifest"],
            models_dir=paths["models"],
            fused_cache=paths["models"] / "debug-fused",
            destination=tmp_path / "Build" / "CREG.app" / "SQLModel",
            manifest_destination=tmp_path / "Build" / "CREG.app" / "model-manifest.json",
            receipt_destination=tmp_path / "Build" / "CREG.app" / "production-model-receipt.json",
            runner=fake_fusion_runner,
        )


def test_debug_materializer_direct_entrypoint():
    completed = subprocess.run(
        [sys.executable, "tools/materialize_debug_model.py", "--help"],
        cwd=Path(__file__).resolve().parents[1],
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    assert "--latest-local-v3" in completed.stdout
    assert "--training-run" in completed.stdout
