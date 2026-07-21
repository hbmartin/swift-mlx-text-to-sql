from pathlib import Path

import mlx.core as mx
import numpy as np
import pytest

from eval.run_artifacts import (
    RunArtifactError,
    create_run_directory,
    clean_git_provenance,
    default_run_id,
    percentile,
)
import eval.run_artifacts as run_artifacts


def test_run_directory_is_immutable(tmp_path):
    created = create_run_directory(tmp_path, "run-1")
    assert created == tmp_path / "run-1"
    with pytest.raises(RunArtifactError, match="will not be overwritten"):
        create_run_directory(tmp_path, "run-1")


def test_default_run_id_records_configuration():
    run_id = default_run_id("qwen25-coder-3b", Path("gold_v2.jsonl"), "on", 0.3, 4)
    assert "qwen25-coder-3b" in run_id
    assert "gold-v2" in run_id
    assert "gcd-on" in run_id
    assert "t-0_3" in run_id
    assert run_id.endswith("-s-4")


def test_percentile_is_deterministic():
    assert percentile([50, 10, 30, 20, 40], 0.95) == 50
    assert percentile([], 0.95) == 0


def test_campaign_provenance_rejects_a_dirty_worktree(monkeypatch):
    monkeypatch.setattr(
        run_artifacts,
        "git_provenance",
        lambda: {"commit": "a" * 40, "branch": "main", "dirty": True},
    )
    with pytest.raises(RunArtifactError, match="clean Git worktree"):
        clean_git_provenance()


def test_recorded_item_seed_replays_mlx_randomness():
    item_seed = 4 * 1_000_000 + 17
    mx.random.seed(item_seed)
    first_array = mx.random.uniform(shape=(16,))
    mx.eval(first_array)
    first = np.array(first_array)
    mx.random.seed(item_seed)
    replay_array = mx.random.uniform(shape=(16,))
    mx.eval(replay_array)
    replay = np.array(replay_array)
    assert np.array_equal(first, replay)
