import json

import pytest

from eval.run_artifacts import git_provenance
from tools.fetch_model import (
    ArtifactError,
    LOCK_FILE,
    copy_production,
    declared_directory_sha256,
    directory_digest,
    directory_inventory,
    verify_artifact_tree_at_use,
)


def make_artifact_tree(tmp_path):
    directory = tmp_path / "model"
    directory.mkdir()
    (directory / "config.json").write_text('{"model_type": "test"}\n')
    (directory / "weights.bin").write_bytes(b"\x00\x01\x02")
    digest = directory_digest(directory_inventory(directory))
    (directory / LOCK_FILE).write_text(
        json.dumps({"directory_sha256": digest})
    )
    artifact = {"snapshot_directory_sha256": digest}
    return directory, artifact, digest


def test_verify_artifact_tree_at_use_accepts_intact_tree(tmp_path):
    directory, artifact, digest = make_artifact_tree(tmp_path)
    assert verify_artifact_tree_at_use(directory, artifact) == digest


def test_verify_artifact_tree_at_use_rejects_modified_bytes(tmp_path):
    directory, artifact, _ = make_artifact_tree(tmp_path)
    (directory / "weights.bin").write_bytes(b"\xff\x01\x02")
    with pytest.raises(ArtifactError, match="does not match the manifest"):
        verify_artifact_tree_at_use(directory, artifact)


def test_verify_artifact_tree_at_use_rejects_stale_lock(tmp_path):
    directory, artifact, _ = make_artifact_tree(tmp_path)
    (directory / "extra.bin").write_bytes(b"planted")
    artifact["snapshot_directory_sha256"] = directory_digest(
        directory_inventory(directory)
    )
    with pytest.raises(ArtifactError, match="artifact lock is stale"):
        verify_artifact_tree_at_use(directory, artifact)


def test_declared_directory_sha256_prefers_conversion():
    assert declared_directory_sha256(
        {
            "snapshot_directory_sha256": "a" * 64,
            "conversion": {"directory_sha256": "b" * 64},
        }
    ) == "b" * 64
    assert (
        declared_directory_sha256({"snapshot_directory_sha256": "a" * 64})
        == "a" * 64
    )


def test_copy_production_refuses_to_delete_unrelated_directories(tmp_path):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    (destination / "precious.txt").write_text("not a model bundle")
    with pytest.raises(ArtifactError, match="refusing to delete"):
        copy_production(
            source,
            destination,
            {"license": {}},
            local_files_only=True,
        )
    assert (destination / "precious.txt").read_text() == "not a model bundle"


def test_copy_production_replaces_prior_bundles_and_excludes_the_lock(
    tmp_path,
):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = tmp_path / "SQLModel"
    for _ in range(2):  # first materialization, then replacement
        copy_production(
            source,
            destination,
            {"license": {}},
            local_files_only=True,
        )
    assert (destination / "config.json").is_file()
    assert (destination / "weights.bin").is_file()
    assert not (destination / LOCK_FILE).exists()


def test_git_provenance_is_strict_and_records_a_real_commit():
    provenance = git_provenance()
    assert len(provenance["commit"]) == 40
    assert all(c in "0123456789abcdef" for c in provenance["commit"])
    assert isinstance(provenance["dirty"], bool)
