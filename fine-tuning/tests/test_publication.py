import json

import pytest

from tools.fetch_model import (
    LOCK_FILE,
    directory_digest,
    directory_inventory,
)
from tools.publish_finalists import (
    model_card,
    repository_slug,
    unexpected_fresh_paths,
    verify_fused_tree_for_publication,
)


def training_fixture() -> dict:
    return {
        "run_id": "qlora-qwen25-coder-3b-seed-424242",
        "git": {"commit": "a" * 40, "dirty": True},
        "base": {
            "repository": "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
            "revision": "b" * 40,
            "lock": {"sha256": "c" * 64},
        },
        "configuration": {"sha256": "d" * 64},
        "corpus": {
            "manifest": {"sha256": "e" * 64},
            "gold_v2_held_out": {"sha256": "f" * 64},
            "files": [
                {
                    "byte_for_byte_equal": True,
                    "committed": {
                        "path": "fine-tuning/synth/out/train.jsonl",
                        "sha256": "1" * 64,
                    },
                }
            ],
        },
        "inputs": {
            "training_runner": {"sha256": "2" * 64},
            "corpus_generator": {"sha256": "3" * 64},
            "model_manifest": {"sha256": "4" * 64},
            "uv_lock": {"sha256": "5" * 64},
        },
        "candidate_manifest_entry": {
            "training_provenance": {
                "base_directory_sha256": "6" * 64,
                "adapter_files": [
                    {
                        "path": "adapters.safetensors",
                        "size": 1,
                        "sha256": "7" * 64,
                    }
                ],
                "training_log_sha256": "8" * 64,
            }
        },
    }


def test_publication_slug_uses_the_complete_base_repository():
    assert repository_slug(
        "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit"
    ) == "mlx-community-qwen2-5-coder-3b-instruct-4bit"


def test_publication_rehashes_the_fused_tree_before_binding_evidence(
    tmp_path,
):
    fused = tmp_path / "fused"
    fused.mkdir()
    (fused / "config.json").write_text("{}\n")
    (fused / "weights.bin").write_bytes(b"original")
    inventory = directory_inventory(fused)
    digest = directory_digest(inventory)
    lock = {
        "directory_sha256": digest,
        "all_files": inventory,
    }
    (fused / LOCK_FILE).write_text(json.dumps(lock))

    actual, verified_inventory = verify_fused_tree_for_publication(
        fused, lock
    )
    assert actual == digest
    assert verified_inventory == inventory

    (fused / "weights.bin").write_bytes(b"tampered")
    with pytest.raises(RuntimeError, match="changed after training/evaluation"):
        verify_fused_tree_for_publication(fused, lock)


def test_fresh_publication_scan_rejects_unstaged_lock_and_cache_files(tmp_path):
    fresh = tmp_path / "fresh"
    (fresh / ".cache" / "huggingface" / "download").mkdir(parents=True)
    (fresh / ".cache" / "unexpected").mkdir(parents=True)
    (fresh / "weights.bin").write_bytes(b"weights")
    (fresh / ".gitattributes").write_text("*.bin filter=lfs\n")
    (fresh / ".creg-artifact.json").write_text("{}\n")
    (fresh / ".cache" / "huggingface" / "download" / "weights.metadata").write_text(
        "local download metadata\n"
    )
    (fresh / ".cache" / "unexpected" / "planted.txt").write_text("planted\n")

    assert unexpected_fresh_paths(fresh, {"weights.bin"}) == [
        ".cache/unexpected/planted.txt",
        ".creg-artifact.json",
    ]


def test_fresh_publication_scan_accepts_only_staged_and_hub_local_files(tmp_path):
    fresh = tmp_path / "fresh"
    (fresh / ".cache" / "huggingface" / "download").mkdir(parents=True)
    (fresh / "weights.bin").write_bytes(b"weights")
    (fresh / ".gitattributes").write_text("*.bin filter=lfs\n")
    (fresh / ".cache" / "huggingface" / "download" / "weights.metadata").write_text(
        "local download metadata\n"
    )

    assert unexpected_fresh_paths(fresh, {"weights.bin"}) == []


def test_qwen_model_card_contains_complete_hash_and_license_evidence():
    card = model_card(
        repo_id=(
            "hbmartin/creg-sql-"
            "mlx-community-qwen2-5-coder-3b-instruct-4bit-mlx-4bit"
        ),
        training=training_fixture(),
        training_configuration_yaml=(
            "seed: 424242\n"
            "iters: 600\n"
            "batch_size: 4\n"
            "num_layers: 16\n"
        ),
        results=[
            {
                "gold": "gold_v2.jsonl",
                "gcd": "off",
                "temperature": 0.0,
                "seed": 0,
                "ex": 0.5,
                "valid_sql_rate": 0.9,
                "p95_microseconds": 123,
                "_evidence": {
                    "run_id": "immutable-eval",
                    "manifest_sha256": "9" * 64,
                    "summary_sha256": "0" * 64,
                },
            }
        ],
        license_id="qwen-research",
        license_url="https://example.invalid/LICENSE",
        commercial=False,
        output_inventory=[
            {"path": "config.json", "size": 1, "sha256": "a" * 64}
        ],
        training_fused_tree_sha256="b" * 64,
    )
    normalized = " ".join(card.split())

    for expected in (
        "Non-commercial use only",
        "Built/Improved using Qwen",
        "`NOTICE`",
        "Base artifact lock SHA-256",
        "Adapter tree SHA-256",
        "Training log SHA-256",
        "Model payload SHA-256",
        "manifest SHA-256",
        "summary SHA-256",
        "byte-for-byte regeneration: `true`",
        "seed: 424242",
        "num_layers: 16",
    ):
        assert expected in normalized
