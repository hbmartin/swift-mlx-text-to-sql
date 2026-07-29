import hashlib
import json
from pathlib import Path

import pytest

from tools.fetch_model import (
    ArtifactError,
    DEVICE_RUNTIME_VERIFICATION_MLP_ADDITIONAL_CONFIDENCE_SKIPS,
    DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP,
    DEVICE_RUNTIME_SPECULATIVE_DECODING,
    directory_digest,
    directory_inventory,
    load_manifest,
    verify_required_files,
)

ROOT = Path(__file__).resolve().parents[2]


def test_manifest_pins_every_referenced_model():
    manifest = load_manifest(ROOT / "model-manifest.json")
    models = {model["key"]: model for model in manifest["models"]}
    base_keys = {
        "qwen25-coder-3b",
        "qwen25-coder-1_5b",
        "qwen3-1_7b",
        "xiyansql-qwencoder-3b",
    }
    assert base_keys <= set(models)
    bases = [model for model in models.values() if not model.get("derived")]
    assert {model["key"] for model in bases} == base_keys
    assert all(len(model["revision"]) == 40 for model in bases)
    qwen_3b = models["qwen25-coder-3b"]
    assert qwen_3b["license"]["id"] == "qwen-research"
    assert qwen_3b["license"]["commercial_use"] is False
    assert (
        qwen_3b["license"]["required_distribution_file"]["path"]
        == "LICENSE"
    )
    assert qwen_3b["license"]["required_notice_file"]["path"] == "NOTICE"
    xiyan = models["xiyansql-qwencoder-3b"]
    assert xiyan["license"]["id"] == "qwen-research-and-apache-2.0"
    assert xiyan["license"]["commercial_use"] is False
    assert {
        item["path"]
        for item in xiyan["license"]["required_distribution_files"]
    } == {"LICENSE", "QWEN_LICENSE"}
    assert xiyan["license"]["required_notice_file"]["path"] == "NOTICE"
    assert (
        xiyan["license"]["lineage_evidence"]["value"]
        == "model/Qwen/Qwen2___5-Coder-3B-Instruct"
    )
    for artifact in (qwen_3b, xiyan):
        notice = artifact["license"]["required_notice_file"]
        source = ROOT / notice["source_path"]
        assert source.stat().st_size == notice["size"]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == notice["sha256"]
    for derived in (model for model in models.values() if model.get("derived")):
        assert derived["publication_status"] in {
            "local-unpublished",
            "public-verified",
        }
        if derived["publication_status"] == "public-verified":
            assert len(derived["revision"]) == 40
    if manifest["production"] is None:
        assert manifest["production_status"] == "selection_pending"
    else:
        assert manifest["production_status"] == "verified"


def test_manifest_rejects_floating_revision(tmp_path):
    manifest = {
        "schema_version": 1,
        "models": [
            {
                "key": "bad",
                "repository": "owner/model",
                "revision": "main",
                "format": "mlx",
                "local_directory": "bad",
                "required_files": [{"path": "config.json"}],
            }
        ],
        "production": None,
    }
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    with pytest.raises(ArtifactError, match="40-character"):
        load_manifest(path)


def test_manifest_rejects_unverified_production_status(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"] = {
        "model_key": "qwen25-coder-3b",
        "gcd": "off",
        "temperature": 0.0,
        "top_p": 1.0,
        "top_k": 0,
        "max_tokens": 512,
        "voting": {
            "candidate_count": 3,
            "sample_temperature": 0.3,
            "always_vote": True,
        },
    }
    manifest["production_status"] = "selection_pending"
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))
    with pytest.raises(ArtifactError, match="production_status 'verified'"):
        load_manifest(path)


@pytest.mark.parametrize(
    ("device_runtime", "message"),
    [
        (
            {
                "policy_version": "unknown",
                "gcd": "off",
                "max_tokens": 128,
            },
            "device_runtime policy_version",
        ),
        (
            {
                "policy_version": "iphone-30-second-v1",
                "gcd": "off",
                "max_tokens": 513,
            },
            "no larger than production max_tokens",
        ),
        (
            {
                "policy_version": "iphone-30-second-v1",
                "gcd": "off",
                "max_tokens": 128,
                "speculative_decoding": {
                    **DEVICE_RUNTIME_SPECULATIVE_DECODING,
                    "draft_tokens": 1,
                },
            },
            "speculative_decoding must exactly match",
        ),
        (
            {
                "policy_version": "iphone-30-second-v2",
                "gcd": "off",
                "max_tokens": 128,
            },
            "requires a 10 MB Metal command-buffer limit",
        ),
        (
            {
                "policy_version": "iphone-30-second-v2",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 40,
            },
            "requires a 10 MB Metal command-buffer limit",
        ),
        (
            {
                "policy_version": "iphone-30-second-v1",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
            },
            "v1 device_runtime cannot declare",
        ),
        (
            {
                "policy_version": "iphone-30-second-v2",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
            },
            "v2 device_runtime cannot declare Qwen2 MLP fusion",
        ),
        (
            {
                "policy_version": "iphone-30-second-v3",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": False,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v3 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v4",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "question_aware_output_head": False,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v4 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v5",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": False,
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v5 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v6",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": False,
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v6 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v7",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": True,
                "verification_mlp_skip_layers": [8],
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v7 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v8",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": True,
                "verification_mlp_skip_layers": [8, 10],
                "verification_mlp_long_batch_extra_skip_layers": [14],
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v8 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v9",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": True,
                "verification_mlp_skip_layers": [8, 10],
                "verification_mlp_long_batch_extra_skip_layers": [2],
                "verification_mlp_confidence_skip": {
                    **DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP,
                    "minimum_support": 256,
                },
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v9 device_runtime requires the evaluated",
        ),
        (
            {
                "policy_version": "iphone-30-second-v10",
                "gcd": "off",
                "max_tokens": 128,
                "metal_command_buffer_limit_mb": 10,
                "compiled_qwen2_mlp_fusion": True,
                "compiled_qwen2_qkv_verification_fusion": True,
                "verification_mlp_skip_layers": [8, 10],
                "verification_mlp_long_batch_extra_skip_layers": [2],
                "verification_mlp_confidence_skip": (
                    DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP
                ),
                "verification_mlp_additional_confidence_skips": [],
                "question_aware_output_head": True,
                "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
            },
            "v10 device_runtime requires the evaluated",
        ),
    ],
)
def test_manifest_rejects_invalid_device_runtime(
    tmp_path, device_runtime, message
):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = device_runtime
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    with pytest.raises(ArtifactError, match=message):
        load_manifest(path)


def test_manifest_accepts_exact_v3_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v3",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v3"
    )


def test_manifest_accepts_exact_v4_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v4",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v4"
    )


def test_manifest_accepts_exact_v5_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v5",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v5"
    )


def test_manifest_accepts_exact_v6_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v6",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v6"
    )


def test_manifest_accepts_exact_v7_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v7",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "verification_mlp_skip_layers": [8, 10],
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v7"
    )


def test_manifest_accepts_exact_v8_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v8",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "verification_mlp_skip_layers": [8, 10],
        "verification_mlp_long_batch_extra_skip_layers": [2],
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v8"
    )


def test_manifest_accepts_exact_v9_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v9",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "verification_mlp_skip_layers": [8, 10],
        "verification_mlp_long_batch_extra_skip_layers": [2],
        "verification_mlp_confidence_skip": (
            DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP
        ),
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v9"
    )


def test_manifest_accepts_exact_v10_device_runtime(tmp_path):
    manifest = load_manifest(ROOT / "model-manifest.json")
    manifest["production"]["device_runtime"] = {
        "policy_version": "iphone-30-second-v10",
        "gcd": "off",
        "max_tokens": 128,
        "metal_command_buffer_limit_mb": 10,
        "compiled_qwen2_mlp_fusion": True,
        "compiled_qwen2_qkv_verification_fusion": True,
        "verification_mlp_skip_layers": [8, 10],
        "verification_mlp_long_batch_extra_skip_layers": [2],
        "verification_mlp_confidence_skip": (
            DEVICE_RUNTIME_VERIFICATION_MLP_CONFIDENCE_SKIP
        ),
        "verification_mlp_additional_confidence_skips": (
            DEVICE_RUNTIME_VERIFICATION_MLP_ADDITIONAL_CONFIDENCE_SKIPS
        ),
        "question_aware_output_head": True,
        "speculative_decoding": DEVICE_RUNTIME_SPECULATIVE_DECODING,
    }
    path = tmp_path / "model-manifest.json"
    path.write_text(json.dumps(manifest))

    assert (
        load_manifest(path)["production"]["device_runtime"]["policy_version"]
        == "iphone-30-second-v10"
    )


def test_required_file_verification_checks_full_hash(tmp_path):
    payload = b"model bytes"
    (tmp_path / "model.safetensors").write_bytes(payload)
    artifact = {
        "key": "test",
        "repository": "owner/model",
        "revision": "a" * 40,
        "format": "mlx",
        "snapshot_directory_sha256": directory_digest(directory_inventory(tmp_path)),
        "required_files": [
            {
                "path": "model.safetensors",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        ],
    }
    lock = verify_required_files(tmp_path, artifact)
    assert lock["verified_files"][0]["sha256"] == hashlib.sha256(payload).hexdigest()

    (tmp_path / "model.safetensors").write_bytes(b"other bytes")
    with pytest.raises(ArtifactError):
        verify_required_files(tmp_path, artifact)
