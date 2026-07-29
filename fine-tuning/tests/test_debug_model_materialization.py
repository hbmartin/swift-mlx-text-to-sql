import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import tools.materialize_debug_model as debug_materializer
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
    elif "convert" in command:
        source = Path(command[command.index("--hf-path") + 1])
        destination = Path(command[command.index("--mlx-path") + 1])
        shutil.copytree(source, destination)
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
    assert generated["debug_candidate"]["model_key"].endswith("-q4-g128-v2")
    assert generated["debug_candidate"]["device_quantization"] == {
        "bits": 4,
        "group_size": 128,
        "mode": "affine",
    }
    assert (
        generated["debug_candidate"]["device_quantization_policy_version"]
        == "iphone-q4-g128-v2"
    )
    assert generated["production"]["voting"]["candidate_count"] == 1
    assert generated["production"]["device_runtime"] == {
        "policy_version": "iphone-30-second-v10",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "verification_mlp_skip_layers": [8, 10],
        "verification_mlp_long_batch_extra_skip_layers": [2],
        "verification_mlp_confidence_skip": {
            "layer": 16,
            "target_input_length": 3,
            "minimum_support": 512,
            "requires_unanimity": True,
        },
        "verification_mlp_additional_confidence_skips": [
            {
                "layer": 35,
                "target_input_length": 2,
                "minimum_support": 512,
                "requires_unanimity": True,
            }
        ],
        "question_aware_output_head": True,
        "speculative_decoding": {
            "strategy": "sql-ngram-target-verification-v3",
            "order": 6,
            "draft_tokens": 3,
            "serial_prefix_tokens": 1,
            "adaptive_draft_min_support": 8,
            "corpus_sha256": (
                "a7cc3c8cc3d7771353c5133c24f6516d201d31a25897949c94d048684c8244dc"
            ),
            "source_corpus_sha256": (
                "3a9ad4806692cdc89e8e68c77e29c5e1eedaefac5745c3a87bd4e4fb1758021e"
            ),
            "statement_count": 1_353,
        },
    }
    receipt = json.loads((resources / "production-model-receipt.json").read_text())
    assert receipt["debug_candidate"]["training_run_id"] == "run-new"
    assert receipt["wandb_receipt_required"] is False
    assert (resources / "SQLModel" / "model.safetensors").is_file()
    debug_artifact = generated["models"][-1]
    assert debug_artifact["quantization"] == {
        "bits": 4,
        "group_size": 128,
        "mode": "affine",
    }
    derivation = debug_artifact["derivation"]
    source_digest = derivation.pop("source_fused_directory_sha256")
    assert source_digest
    assert derivation == {
        "policy_version": "iphone-q4-g128-v2",
        "source_quantization": {
            "bits": 4,
            "group_size": 64,
            "mode": "affine",
        },
        "pipeline": "fuse-dequantize-requantize-v1",
    }
    cache = next((paths["models"] / "debug-fused").glob("*q4-g128-affine-v2"))
    lock = json.loads((cache / LOCK_FILE).read_text())
    assert lock["source_fused_directory_sha256"] == source_digest
    assert lock["directory_sha256"] == debug_artifact["snapshot_directory_sha256"]


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


def test_evaluated_device_artifact_fails_closed_on_source_drift(
    tmp_path, monkeypatch
):
    paths = fixture(tmp_path)
    training = json.loads((paths["run"] / "manifest.json").read_text())
    selected = training["checkpoint_evaluation"]["selected"]
    monkeypatch.setitem(
        debug_materializer.EVALUATED_DEVICE_ARTIFACTS,
        "run-new",
        {
            "selected_iteration": selected["iteration"],
            "selected_checkpoint_sha256": selected["checkpoint_sha256"],
            "source_fused_directory_sha256": "0" * 64,
            "device_directory_sha256": "1" * 64,
        },
    )

    with pytest.raises(ArtifactError, match="latency/accuracy-evaluated bytes"):
        materialize_debug_model(
            paths["run"],
            model_manifest_path=paths["manifest"],
            models_dir=paths["models"],
            fused_cache=paths["models"] / "debug-fused",
            destination=tmp_path / "Build" / "CREG.app" / "SQLModel",
            manifest_destination=tmp_path / "Build" / "CREG.app" / "model-manifest.json",
            receipt_destination=tmp_path
            / "Build"
            / "CREG.app"
            / "production-model-receipt.json",
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
