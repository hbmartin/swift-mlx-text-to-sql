import hashlib
import json
import shutil
import subprocess
import sys

import pytest

from eval.run_artifacts import git_provenance
import tools.fetch_model as fetch_model
from tools.fetch_model import (
    ArtifactError,
    LOCK_FILE,
    PRODUCTION_RECEIPT_FILE,
    copy_distribution_license,
    copy_production,
    declared_directory_sha256,
    directory_digest,
    directory_inventory,
    require_current_production_policy,
    verify_artifact_tree_at_use,
)


def test_fetch_model_direct_script_entrypoint_resolves_shared_integrity():
    completed = subprocess.run(
        [sys.executable, "tools/fetch_model.py", "--help"],
        cwd=fetch_model.REPO_ROOT / "fine-tuning",
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    assert "--production" in completed.stdout
    assert "--allow-historical-policy" in completed.stdout


def test_historical_policy_exception_is_rejected_outside_production_mode():
    completed = subprocess.run(
        [
            sys.executable,
            "tools/fetch_model.py",
            "--model",
            "qwen25-coder-3b",
            "--allow-historical-policy",
        ],
        cwd=fetch_model.REPO_ROOT / "fine-tuning",
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 1
    assert (
        "--allow-historical-policy is valid only with --production"
        in completed.stderr
    )


def test_historical_policy_requires_an_explicit_rollout_exception():
    historical = {"model_key": "historical"}

    with pytest.raises(ArtifactError, match="historical policy evidence"):
        require_current_production_policy(
            historical,
            allow_historical_policy=False,
        )

    require_current_production_policy(
        historical,
        allow_historical_policy=True,
    )


def test_bounded_policy_never_needs_the_rollout_exception():
    require_current_production_policy(
        {"policy_version": "bounded-three-generation-v1"},
        allow_historical_policy=False,
    )


def test_distribution_files_already_in_verified_artifact_avoid_hub_symlinks(
    tmp_path, monkeypatch
):
    license_bytes = b"pinned license bytes\n"
    notice_bytes = b"pinned notice bytes\n"
    (tmp_path / "LICENSE").write_bytes(license_bytes)
    (tmp_path / "NOTICE").write_bytes(notice_bytes)
    artifact = {
        "license": {
            "required_distribution_file": {
                "path": "LICENSE",
                "source_path": "LICENSE",
                "source_repository": "owner/source",
                "source_revision": "a" * 40,
                "size": len(license_bytes),
                "sha256": hashlib.sha256(license_bytes).hexdigest(),
            },
            "required_notice_file": {
                "path": "NOTICE",
                "source_path": "missing-notice.txt",
                "size": len(notice_bytes),
                "sha256": hashlib.sha256(notice_bytes).hexdigest(),
            },
        }
    }

    def fail_download(**_kwargs):
        raise AssertionError("verified bundled licenses must not hit the Hub")

    monkeypatch.setattr(fetch_model, "hf_hub_download", fail_download)
    copy_distribution_license(artifact, tmp_path, local_files_only=False)


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
    (destination / "config.json").write_text(
        '{"application": "not-a-model"}\n'
    )
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


def test_copy_production_failure_preserves_prior_bundle(tmp_path, monkeypatch):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = tmp_path / "SQLModel"
    artifact = {"license": {}}
    copy_production(source, destination, artifact, local_files_only=True)
    before = (destination / "weights.bin").read_bytes()

    def fail_license(*_args, **_kwargs):
        raise ArtifactError("injected license failure")

    monkeypatch.setattr(fetch_model, "copy_distribution_license", fail_license)
    with pytest.raises(ArtifactError, match="injected license failure"):
        copy_production(source, destination, artifact, local_files_only=True)

    assert (destination / "weights.bin").read_bytes() == before
    assert (destination / "config.json").is_file()


def test_copy_production_writes_manifest_bound_receipt(tmp_path):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = tmp_path / "Resources" / "SQLModel"
    manifest = tmp_path / "model-manifest.json"
    manifest.write_text('{"production_status":"verified"}\n')
    artifact = {
        "key": "winner",
        "repository": "owner/winner",
        "revision": "a" * 40,
        "license": {},
    }

    copy_production(
        source,
        destination,
        artifact,
        local_files_only=True,
        source_manifest=manifest,
    )

    receipt = json.loads(
        (destination.parent / PRODUCTION_RECEIPT_FILE).read_text()
    )
    assert receipt["model_key"] == "winner"
    assert receipt["repository"] == "owner/winner"
    assert receipt["revision"] == "a" * 40
    assert receipt["file_count"] == 2
    assert len(receipt["directory_sha256"]) == 64
    assert len(receipt["source_manifest_sha256"]) == 64


@pytest.mark.parametrize("kind", ["file", "directory"])
def test_inventory_rejects_symbolic_links(tmp_path, kind):
    directory = tmp_path / "tree"
    directory.mkdir()
    target = tmp_path / "target"
    if kind == "file":
        target.write_bytes(b"secret")
    else:
        target.mkdir()
        (target / "secret.bin").write_bytes(b"secret")
    (directory / "linked").symlink_to(target, target_is_directory=kind == "directory")

    with pytest.raises(ArtifactError, match="symbolic links are not allowed"):
        directory_inventory(directory)


def test_copy_production_replaces_a_legacy_bundle_with_the_exact_lock(
    tmp_path,
):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = tmp_path / "SQLModel"
    shutil.copytree(source, destination)

    copy_production(
        source,
        destination,
        {"license": {}},
        local_files_only=True,
    )

    assert (destination / "weights.bin").read_bytes() == b"\x00\x01\x02"
    assert not (destination / LOCK_FILE).exists()


def test_copy_production_refuses_overlapping_source_and_destination(
    tmp_path,
):
    source, _, _ = make_artifact_tree(tmp_path)
    destination = source / "nested-bundle"

    with pytest.raises(ArtifactError, match="must be disjoint"):
        copy_production(
            source,
            destination,
            {"license": {}},
            local_files_only=True,
        )


def test_git_provenance_is_strict_and_records_a_real_commit():
    provenance = git_provenance()
    assert len(provenance["commit"]) == 40
    assert all(c in "0123456789abcdef" for c in provenance["commit"])
    assert isinstance(provenance["dirty"], bool)
