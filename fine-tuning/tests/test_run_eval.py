import argparse

import pytest

from eval.run_eval import positive_int, report_sql_score, rounded_mean
from synth.generate_training import AS_OF_DATE, SYSTEM_PROMPT as SYNTH_SYSTEM_PROMPT
from eval.run_eval import AS_OF_DATE_PATH, SYSTEM_PROMPT as EVAL_SYSTEM_PROMPT


def test_positive_int_rejects_zero_and_negative_values():
    assert positive_int("3") == 3
    with pytest.raises(argparse.ArgumentTypeError):
        positive_int("0")
    with pytest.raises(argparse.ArgumentTypeError):
        positive_int("-1")


def test_rounded_mean_keeps_zero_and_reports_missing_data():
    assert rounded_mean([0.0, 0.0], 4) == 0.0
    assert rounded_mean([], 4) is None


def test_fallback_sql_is_excluded_but_retains_its_diagnostic_score():
    assert report_sql_score(
        "best_guess_fallback", True, "scored", "correct"
    ) == (
        None,
        "excluded-fallback-sql",
        "excluded-fallback-sql",
        True,
        "scored",
        "correct",
    )
    assert report_sql_score("primary", False, "scored", "wrong-projection") == (
        False, "scored", "wrong-projection", None, None, None)


def test_python_prompts_share_the_fixed_as_of_date():
    as_of_date = AS_OF_DATE_PATH.read_text().strip()
    assert as_of_date == AS_OF_DATE
    assert EVAL_SYSTEM_PROMPT.format(
        schema="schema", as_of_date=as_of_date
    ) == SYNTH_SYSTEM_PROMPT.format(schema="schema", as_of_date=AS_OF_DATE)
