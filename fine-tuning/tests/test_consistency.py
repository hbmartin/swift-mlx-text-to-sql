import json
from pathlib import Path

import pytest

import eval.run_consistency as consistency
from eval.run_consistency import run_is_compatible
from eval.run_artifacts import sha256_file
from eval.selection import Run
from eval.selection import SelectionError
from tools.analyze_consistency import load_calibration
from tools.fetch_model import (
    ArtifactError,
    LOCK_FILE,
    directory_digest,
    directory_inventory,
)


def compatible_run() -> Run:
    return Run(
        directory=Path("/tmp/run"),
        manifest={
            "model": {
                "repository": "owner/model",
                "revision": "a" * 40,
            },
            "configuration": {
                "top_p": 1.0,
                "top_k": 0,
                "max_tokens": 512,
                "item_seed_formula":
                    "run_seed * 1000000 + zero_based_item_index",
            },
            "inputs": {"gold": {"sha256": "b" * 64}},
            "hardware": {"model": "test-mac"},
        },
        summary={
            "model_key": "winner",
            "gcd": "on",
            "temperature": 0.3,
            "seed": 4,
            "n": 200,
        },
        items=(),
    )


def test_run_is_compatible_requires_exact_evaluation_identity() -> None:
    run = compatible_run()
    arguments = {
        "model": "winner",
        "repository": "owner/model",
        "revision": "a" * 40,
        "gcd": "on",
        "temperature": 0.3,
        "seed": 4,
        "gold_sha256": "b" * 64,
        "hardware": {"model": "test-mac"},
    }
    assert run_is_compatible(run, **arguments)

    for key, incompatible in (
        ("model", "other"),
        ("repository", "other/model"),
        ("revision", "c" * 40),
        ("gcd", "off"),
        ("temperature", 0.7),
        ("seed", 3),
        ("gold_sha256", "d" * 64),
        ("hardware", {"model": "other-mac"}),
    ):
        changed = dict(arguments)
        changed[key] = incompatible
        assert not run_is_compatible(run, **changed)


def test_run_is_compatible_rejects_noncanonical_sampler_settings() -> None:
    run = compatible_run()
    run.manifest["configuration"]["top_k"] = 20
    assert not run_is_compatible(
        run,
        model="winner",
        repository="owner/model",
        revision="a" * 40,
        gcd="on",
        temperature=0.3,
        seed=4,
        gold_sha256="b" * 64,
    )


def test_run_is_compatible_requires_all_frozen_input_hashes() -> None:
    run = compatible_run()
    run.manifest["model"].update(
        {
            "artifact_lock": {"sha256": "c" * 64},
            "directory_sha256": "d" * 64,
        }
    )
    input_sha256 = {
        "database": "e" * 64,
        "grammar": "f" * 64,
        "schema_prompt": "0" * 64,
        "swift_package_lock": "1" * 64,
        "uv_lock": "2" * 64,
        "tokenizer": "3" * 64,
        "system_prompt_sha256": "4" * 64,
    }
    run.manifest["inputs"].update(
        {
            name: (
                digest
                if name == "system_prompt_sha256"
                else {"sha256": digest}
            )
            for name, digest in input_sha256.items()
        }
    )
    arguments = {
        "model": "winner",
        "repository": "owner/model",
        "revision": "a" * 40,
        "gcd": "on",
        "temperature": 0.3,
        "seed": 4,
        "gold_sha256": "b" * 64,
        "input_sha256": input_sha256,
        "artifact_lock_sha256": "c" * 64,
        "directory_sha256": "d" * 64,
    }
    assert run_is_compatible(run, **arguments)

    run.manifest["inputs"]["grammar"]["sha256"] = "9" * 64
    assert not run_is_compatible(run, **arguments)


def test_current_identity_rehashes_model_weights(monkeypatch, tmp_path) -> None:
    model_directory = tmp_path / "models" / "winner"
    model_directory.mkdir(parents=True)
    (model_directory / "tokenizer.json").write_text("{}\n")
    (model_directory / "weights.bin").write_bytes(b"original")
    digest = directory_digest(directory_inventory(model_directory))
    (model_directory / LOCK_FILE).write_text(
        json.dumps({"directory_sha256": digest})
    )
    artifact = {
        "key": "winner",
        "repository": "owner/model",
        "revision": "a" * 40,
        "local_directory": "winner",
        "snapshot_directory_sha256": digest,
    }

    paths = {}
    for name in (
        "gold",
        "database",
        "grammar",
        "schema",
        "swift-lock",
        "uv-lock",
    ):
        path = tmp_path / name
        path.write_text(name)
        paths[name] = path

    monkeypatch.setattr(consistency, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(consistency, "MODEL_MANIFEST", tmp_path / "manifest")
    monkeypatch.setattr(consistency, "GOLD_V2", paths["gold"])
    monkeypatch.setattr(consistency, "DATABASE", paths["database"])
    monkeypatch.setattr(consistency, "GRAMMAR", paths["grammar"])
    monkeypatch.setattr(consistency, "SCHEMA_PROMPT", paths["schema"])
    monkeypatch.setattr(consistency, "SWIFT_LOCK", paths["swift-lock"])
    monkeypatch.setattr(consistency, "UV_LOCK", paths["uv-lock"])
    monkeypatch.setattr(
        consistency,
        "load_manifest",
        lambda _: {"models": [artifact]},
    )

    identity = consistency.current_identity("winner")
    assert identity["directory_sha256"] == digest

    (model_directory / "weights.bin").write_bytes(b"tampered")
    with pytest.raises(ArtifactError, match="does not match the manifest"):
        consistency.current_identity("winner")


def test_current_identity_normalizes_local_unpublished_artifacts(
    monkeypatch, tmp_path
) -> None:
    model_directory = tmp_path / "models" / "winner"
    model_directory.mkdir(parents=True)
    (model_directory / "tokenizer.json").write_text("{}\n")
    (model_directory / "weights.bin").write_bytes(b"original")
    digest = directory_digest(directory_inventory(model_directory))
    (model_directory / LOCK_FILE).write_text(json.dumps({"directory_sha256": digest}))
    artifact = {
        "key": "winner",
        "repository": None,
        "revision": None,
        "local_directory": "winner",
        "snapshot_directory_sha256": digest,
    }
    paths = {}
    for name in ("gold", "database", "grammar", "schema", "swift-lock", "uv-lock"):
        path = tmp_path / name
        path.write_text(name)
        paths[name] = path
    monkeypatch.setattr(consistency, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(consistency, "MODEL_MANIFEST", tmp_path / "manifest")
    monkeypatch.setattr(consistency, "GOLD_V2", paths["gold"])
    monkeypatch.setattr(consistency, "DATABASE", paths["database"])
    monkeypatch.setattr(consistency, "GRAMMAR", paths["grammar"])
    monkeypatch.setattr(consistency, "SCHEMA_PROMPT", paths["schema"])
    monkeypatch.setattr(consistency, "SWIFT_LOCK", paths["swift-lock"])
    monkeypatch.setattr(consistency, "UV_LOCK", paths["uv-lock"])
    monkeypatch.setattr(consistency, "load_manifest", lambda _: {"models": [artifact]})

    identity = consistency.current_identity("winner")
    assert identity["repository"] == "local-derived"
    assert identity["revision"] == f"sha256:{digest}"


@pytest.mark.parametrize("schema_version", [1, 2])
def test_calibration_loader_rejects_historical_schema_versions(
    tmp_path, schema_version
) -> None:
    directory = tmp_path / f"v{schema_version}"
    directory.mkdir()
    items = directory / "items.jsonl"
    items.write_text("{}\n")
    summary = {
        "schema_version": schema_version,
        "policy_version": "bounded-three-generation-v1",
        "always_vote": True,
        "candidate_count": 3,
        "trial_seeds": [0, 1, 2, 3, 4],
        "n_trials": 1000,
    }
    (directory / "summary.json").write_text(json.dumps(summary))
    manifest = {
        "schema_version": schema_version,
        "policy_version": "bounded-three-generation-v1",
        "status": "complete",
        "outputs": {
            "items": {"path": "items.jsonl", "sha256": sha256_file(items)},
            "summary": {
                "path": "summary.json",
                "sha256": sha256_file(directory / "summary.json"),
            },
        },
    }
    (directory / "manifest.json").write_text(json.dumps(manifest))

    with pytest.raises(SelectionError, match="v1/v2 evidence is historical"):
        load_calibration(directory)


def test_schema_v3_loader_rejects_relabelled_always_vote_evidence(tmp_path) -> None:
    directory = tmp_path / "false-v3"
    directory.mkdir()
    items = directory / "items.jsonl"
    items.write_text("{}\n")
    summary = {
        "schema_version": 3,
        "policy_version": "bounded-three-generation-v1",
        "bounded_policy": False,
        "always_vote": True,
        "candidate_count": 3,
        "sample_temperature": 0.7,
        "trial_seeds": [0, 1, 2, 3, 4],
        "n_trials": 1000,
    }
    (directory / "summary.json").write_text(json.dumps(summary))
    manifest = {
        "schema_version": 3,
        "policy_version": "bounded-three-generation-v1",
        "status": "complete",
        "outputs": {
            "items": {"path": "items.jsonl", "sha256": sha256_file(items)},
            "summary": {
                "path": "summary.json",
                "sha256": sha256_file(directory / "summary.json"),
            },
        },
    }
    (directory / "manifest.json").write_text(json.dumps(manifest))

    with pytest.raises(SelectionError, match="bounded three-generation"):
        load_calibration(directory)


def test_schema_v3_loader_requires_same_hardware_provenance(tmp_path) -> None:
    directory = tmp_path / "no-hardware"
    directory.mkdir()
    items = directory / "items.jsonl"
    items.write_text("{}\n")
    summary = {
        "schema_version": 3,
        "policy_version": "bounded-three-generation-v1",
        "bounded_policy": True,
        "always_vote": False,
        "candidate_count": 3,
        "sample_temperature": 0.7,
        "trial_seeds": [0, 1, 2, 3, 4],
        "n_trials": 1000,
    }
    (directory / "summary.json").write_text(json.dumps(summary))
    manifest = {
        "schema_version": 3,
        "policy_version": "bounded-three-generation-v1",
        "status": "complete",
        "outputs": {
            "items": {"path": "items.jsonl", "sha256": sha256_file(items)},
            "summary": {
                "path": "summary.json",
                "sha256": sha256_file(directory / "summary.json"),
            },
        },
    }
    (directory / "manifest.json").write_text(json.dumps(manifest))

    with pytest.raises(SelectionError, match="same-hardware provenance"):
        load_calibration(directory)


def candidate(
    digest=None,
    row_count=1,
    error=None,
    truncated=False,
    ex=False,
    sql=None,
):
    if sql is None:
        sql = f"SELECT {digest if digest is not None else error or 'value'}"
    predicted = None
    if error is None:
        predicted = {
            "digest": None if truncated else digest,
            "row_count": row_count,
            "is_truncated": truncated,
        }
    return {
        "error": error,
        "predicted": predicted,
        "predicted_sql": sql,
        "ex": ex,
    }


def test_vote_consensus_of_two_samples_beats_the_anchor() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", ex=True)),
            ("sample-1", candidate(digest="b", ex=False)),
            ("sample-2", candidate(digest="b", ex=False)),
        ]
    )
    assert vote["outcome"] == "consensus"
    assert vote["agreement"] == 2
    assert vote["selected_role"] == "sample-1"
    assert vote["ex"] is False
    assert vote["valid_sql"] is True
    assert vote["duplicate_reuses"] == 1


def test_policy_latency_excludes_gold_execution_and_duplicate_execution() -> None:
    from eval.run_consistency import policy_latency_microseconds

    first = candidate(digest="a", sql="SELECT 1") | {
        "generation_microseconds": 100,
        "gold_execution_microseconds": 20,
        "elapsed_microseconds": 150,
    }
    duplicate = candidate(digest="different-eval-result", sql="SELECT 1") | {
        "generation_microseconds": 110,
        "gold_execution_microseconds": 30,
        "elapsed_microseconds": 190,
    }
    unique = candidate(digest="b", sql="SELECT 2") | {
        "generation_microseconds": 120,
        "gold_execution_microseconds": 40,
        "elapsed_microseconds": 210,
    }

    assert policy_latency_microseconds(
        [("anchor", first), ("sample-1", duplicate), ("sample-2", unique)]
    ) == (150 - 20) + 110 + (210 - 40)


def test_vote_empty_results_carry_no_consensus_evidence() -> None:
    from eval.run_consistency import vote_trial

    empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", ex=True)),
            ("sample-1", candidate(digest=empty, row_count=0)),
            ("sample-2", candidate(digest=empty, row_count=0)),
        ]
    )
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "anchor"
    assert vote["ex"] is True


def test_vote_all_empty_delivers_the_empty_anchor() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="e", row_count=0, ex=False)),
            ("sample-1", candidate(digest="e", row_count=0)),
            ("sample-2", candidate(digest="e", row_count=0)),
        ]
    )
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "anchor"


def test_vote_results_beyond_production_row_cap_are_not_eligible() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", ex=True)),
            ("sample-1", candidate(digest="b", row_count=501)),
            ("sample-2", candidate(digest="b", row_count=501)),
        ]
    )
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "anchor"


def test_vote_anchor_beyond_app_cap_is_unconfirmed_and_degraded() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", row_count=501, ex=True)),
            ("sample-1", candidate(digest="b", ex=True)),
            ("sample-2", candidate(digest="c", ex=True)),
        ]
    )
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "anchor"
    assert vote["ex"] is False
    assert vote["valid_sql"] is True


def test_repair_branch_falls_back_to_the_valid_deterministic_repair() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(error="no such column: bogus", sql="SELECT bogus")),
            ("deterministic-repair", candidate(digest="b", ex=True, sql="SELECT 1")),
            ("sampled-repair", candidate(digest="c", ex=False, sql="SELECT 2")),
        ]
    )
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "deterministic-repair"
    assert vote["ex"] is True
    assert vote["valid_sql"] is True


def test_vote_majority_threshold_is_strict_over_candidate_count() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", ex=True)),
            ("sample-1", candidate(error="boom")),
            ("sample-2", candidate(error="boom")),
        ]
    )
    # One vote of three is not a strict majority even though every other
    # candidate failed.
    assert vote["outcome"] == "no-consensus"
    assert vote["selected_role"] == "anchor"


def test_failed_duplicate_is_suppressed_before_selection() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(error="syntax", sql="SELECT bogus")),
            ("deterministic-repair", candidate(error="syntax", sql="SELECT bogus")),
            ("sampled-repair", candidate(digest="ok", ex=True, sql="SELECT 1")),
        ]
    )
    assert vote["duplicate_count"] == 1
    assert vote["selected_role"] == "sampled-repair"
