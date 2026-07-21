import pytest

from eval.selection import (
    Aggregate,
    SelectionError,
    paired_item_bootstrap,
    production_tie_key,
    temperature_is_eligible,
)
from tools.analyze_matrix import (
    identical_sql_runtime_drift,
    normalize_parity_explanations,
)


def aggregate(scores: list[float]) -> Aggregate:
    return Aggregate(
        model_key="m",
        gcd="on",
        temperature=0,
        seeds=(0,),
        item_scores={str(index): score for index, score in enumerate(scores)},
        item_valid={str(index): 1.0 for index in range(len(scores))},
        item_tiers={str(index): 1 for index in range(len(scores))},
        timings_microseconds=(1,),
        bundle_size_bytes=1,
    )


def test_paired_bootstrap_is_deterministic_and_item_clustered():
    baseline = aggregate([0, 0, 1, 1])
    candidate = aggregate([1, 0, 1, 1])
    first = paired_item_bootstrap(candidate, baseline, repetitions=1_000)
    second = paired_item_bootstrap(candidate, baseline, repetitions=1_000)
    assert first == second
    assert first["candidate_minus_baseline"] == 0.25
    assert first["n_items"] == 4


def test_temperature_requires_two_points_and_positive_interval():
    baseline = aggregate([0] * 200)
    candidate = aggregate([1] * 10 + [0] * 190)
    eligible, comparison = temperature_is_eligible(candidate, baseline)
    assert comparison["candidate_minus_baseline"] == 0.05
    assert eligible

    too_small = aggregate([1] * 3 + [0] * 197)
    eligible, _ = temperature_is_eligible(too_small, baseline)
    assert not eligible


def test_production_tie_break_ignores_small_ex_difference():
    source = aggregate([1] * 102 + [0] * 98)
    higher_ex = Aggregate(
        model_key="higher-ex",
        gcd=source.gcd,
        temperature=source.temperature,
        seeds=source.seeds,
        item_scores=source.item_scores,
        item_valid={
            str(index): float(index < 160) for index in range(200)
        },
        item_tiers=source.item_tiers,
        timings_microseconds=source.timings_microseconds,
        bundle_size_bytes=source.bundle_size_bytes,
    )
    higher_valid = Aggregate(
        model_key="more-valid",
        gcd=higher_ex.gcd,
        temperature=higher_ex.temperature,
        seeds=higher_ex.seeds,
        item_scores={
            str(index): float(index < 100) for index in range(200)
        },
        item_valid={str(index): 1.0 for index in range(200)},
        item_tiers=higher_ex.item_tiers,
        timings_microseconds=higher_ex.timings_microseconds,
        bundle_size_bytes=higher_ex.bundle_size_bytes,
    )
    assert higher_ex.ex == 0.51
    assert higher_valid.ex == 0.5
    assert sorted(
        [higher_ex, higher_valid], key=production_tie_key
    )[0] is higher_valid


@pytest.mark.parametrize("invalid", [None, "", "   ", 42])
def test_parity_explanations_reject_values_that_could_hide_stale_ids(invalid):
    with pytest.raises(
        SelectionError,
        match="parity explanations must contain non-empty strings",
    ):
        normalize_parity_explanations(
            {"real-disagreement": "explained", "stale-id": invalid}
        )


def test_parity_explanations_preserve_all_raw_ids_before_normalizing():
    explanations, raw_ids = normalize_parity_explanations(
        {"real-disagreement": "  explained  ", "stale-id": "also valid"}
    )

    assert explanations == {
        "real-disagreement": "explained",
        "stale-id": "also valid",
    }
    assert raw_ids == {"real-disagreement", "stale-id"}


def test_missing_predictions_are_not_identical_sql_runtime_drift():
    missing = {"python": {"sql": None}, "swift": {"sql": None}}
    identical = {
        "python": {"sql": "SELECT 1"},
        "swift": {"sql": "SELECT 1"},
    }

    assert not identical_sql_runtime_drift(missing, "3.49.1", "3.49.1")
    assert identical_sql_runtime_drift(identical, "3.49.1", "3.49.1")
    assert not identical_sql_runtime_drift(identical, "3.49.1", "3.50.0")
