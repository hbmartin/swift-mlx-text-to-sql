import base64
import json
from pathlib import Path

import pytest

from eval.ex import (
    ExecutionError,
    canonical_number,
    execute,
    execute_with_metadata,
    result_digest,
    results_match,
    score,
    typed_rows,
)

DB = Path(__file__).resolve().parents[2] / "db" / "creg.sqlite"
FIXTURES = (
    Path(__file__).resolve().parents[2]
    / "CREGKit"
    / "Sources"
    / "CREGEngine"
    / "Resources"
    / "canonical_result_fixtures.json"
)


def fixture_rows(rows: list[list[dict[str, str]]]) -> list[tuple[object, ...]]:
    def value(cell: dict[str, str]):
        kind = cell["type"]
        raw = cell["value"]
        if kind == "null":
            return None
        if kind == "integer":
            return int(raw)
        if kind == "real":
            return float(raw)
        if kind == "text":
            return raw
        if kind == "blob":
            return base64.b64decode(raw)
        raise AssertionError(f"unknown fixture type: {kind}")

    return [tuple(value(cell) for cell in row) for row in rows]


def test_results_match_is_order_insensitive():
    assert results_match([(1, "a"), (2, "b")], [(2, "b"), (1, "a")])
    assert not results_match([(1,)], [(1,), (1,)])  # multiset, not set
    assert not results_match([(1,)], [(2,)])

def test_numeric_types_match_but_text_does_not():
    assert results_match([(1,)], [(1.0,)])
    assert not results_match([(1,)], [("1",)])


def test_blob_identity_uses_bytes_not_length():
    assert results_match([(b"ab",)], [(b"ab",)])
    assert not results_match([(b"ab",)], [(b"cd",)])


def test_null_is_a_separate_domain():
    assert results_match([(None,)], [(None,)])
    assert not results_match([(None,)], [("",)])


def test_half_even_four_decimal_normalization():
    assert canonical_number(1.00005) == "1"
    assert canonical_number(1.00015) == "1.0002"
    assert canonical_number(-0.0) == "0"


def test_typed_rows_and_digest_are_stable():
    first = [(1, "a", b"\x00"), (2.0, None, b"\xff")]
    second = list(reversed(first))
    assert typed_rows(first) == typed_rows(second)
    assert result_digest(first) == result_digest(second)
    assert typed_rows([(1,)]) != typed_rows([("1",)])


def test_shared_canonical_fixtures():
    document = json.loads(FIXTURES.read_text())
    assert document["schema_version"] == 1
    for case in document["cases"]:
        left = fixture_rows(case["left"])
        right = fixture_rows(case["right"])
        left_encoding = json.dumps(
            typed_rows(left),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        right_encoding = json.dumps(
            typed_rows(right),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        assert left_encoding == case["left_encoding"], case["name"]
        assert right_encoding == case["right_encoding"], case["name"]
        assert result_digest(left) == case["left_digest"], case["name"]
        assert result_digest(right) == case["right_digest"], case["name"]
        assert results_match(left, right) is case["matches"], case["name"]


def test_execute_normalizes_floats():
    rows = execute(DB, "SELECT 1.00004, 'x'")
    assert rows == [(1.0, "x")]


def test_execute_detects_truncation():
    result = execute_with_metadata(
        DB, "SELECT property_id FROM properties ORDER BY property_id", row_cap=1
    )
    assert len(result) == 1
    assert result.is_truncated
    assert not results_match(result, result.rows)


def test_execute_raises_on_bad_sql():
    with pytest.raises(ExecutionError):
        execute(DB, "SELECT nonexistent_column FROM properties")


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
    assert result["error"]
