import hashlib
import json
from pathlib import Path

import pytest

from tools.fetch_model import (
    ArtifactError,
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
