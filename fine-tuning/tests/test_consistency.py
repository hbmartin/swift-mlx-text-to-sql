from pathlib import Path

from eval.run_consistency import run_is_compatible
from eval.selection import Run


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


def candidate(
    digest=None,
    row_count=1,
    error=None,
    truncated=False,
    ex=False,
):
    predicted = None
    if error is None:
        predicted = {
            "digest": None if truncated else digest,
            "row_count": row_count,
            "is_truncated": truncated,
        }
    return {"error": error, "predicted": predicted, "ex": ex}


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


def test_vote_anchor_truncation_is_delivered_degraded_not_substituted() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(digest="a", row_count=501, ex=True)),
            ("sample-1", candidate(digest="b", ex=True)),
            ("sample-2", candidate(digest="c", ex=True)),
        ]
    )
    assert vote["outcome"] == "anchor-failed"
    assert vote["selected_role"] == "anchor"
    assert vote["ex"] is False
    assert vote["valid_sql"] is True


def test_vote_anchor_error_scores_a_failure_not_a_sample() -> None:
    from eval.run_consistency import vote_trial

    vote = vote_trial(
        [
            ("anchor", candidate(error="no such column: bogus")),
            ("sample-1", candidate(digest="b", ex=True)),
            ("sample-2", candidate(digest="c", ex=True)),
        ]
    )
    assert vote["outcome"] == "anchor-failed"
    assert vote["selected_role"] is None
    assert vote["ex"] is False
    assert vote["valid_sql"] is False


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
