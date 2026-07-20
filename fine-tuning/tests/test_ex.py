from pathlib import Path

import pytest

from eval.ex import ExecutionError, RowCapExceeded, execute, results_match, score

DB = Path(__file__).resolve().parents[2] / "db" / "creg.sqlite"


def test_results_match_is_order_insensitive():
    assert results_match([(1, "a"), (2, "b")], [(2, "b"), (1, "a")])
    assert not results_match([(1,)], [(1,), (1,)])  # multiset, not set
    assert not results_match([(1,)], [(2,)])


def test_execute_normalizes_floats():
    rows = execute(DB, "SELECT 1.00004, 'x'")
    assert rows == [(1.0, "x")]


def test_execute_raises_on_bad_sql():
    with pytest.raises(ExecutionError):
        execute(DB, "SELECT nonexistent_column FROM properties")


def test_execute_rejects_truncated_results():
    with pytest.raises(RowCapExceeded):
        execute(DB, "SELECT property_id FROM properties", row_cap=1)


def test_execute_rejects_nonpositive_row_cap():
    with pytest.raises(ValueError):
        execute(DB, "SELECT 1", row_cap=0)


def test_score_matches_equivalent_queries():
    result = score(
        DB,
        "SELECT name FROM properties WHERE status = 'Sold' ORDER BY name",
        "SELECT name FROM properties WHERE status = 'Sold' ORDER BY name DESC",
    )
    assert result["ex"] is True  # order-insensitive


def test_score_flags_wrong_filter():
    result = score(
        DB,
        "SELECT name FROM properties WHERE status = 'Owned'",
        "SELECT name FROM properties WHERE status = 'Sold'",
    )
    assert result["ex"] is False


def test_score_reports_execution_error():
    result = score(DB, "SELECT bogus FROM properties", "SELECT name FROM properties")
    assert result["ex"] is False
    assert result["status"] == "execution-error"
    assert result["error"]


def test_score_marks_row_cap_as_unscorable():
    result = score(
        DB,
        "SELECT name FROM properties",
        "SELECT name FROM properties",
        row_cap=1,
    )
    assert result["ex"] is None
    assert result["status"] == "row-cap-exceeded"
