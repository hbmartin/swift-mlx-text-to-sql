"""Execution Accuracy (EX) scoring core.

EX compares the *result set* of predicted vs gold SQL: order-insensitive
multiset equality over rows, with float tolerance. Known blind spot (PRD §12):
semantically different queries can coincide on results — spot-check with
exact-set-match where needed.
"""

import sqlite3
from collections import Counter
from pathlib import Path

ROW_CAP = 10_000
FLOAT_DECIMALS = 4


class ExecutionError(Exception):
    pass


class RowCapExceeded(ExecutionError):
    """The query returned more rows than the scorer can compare safely."""

    def __init__(self, row_cap: int):
        self.row_cap = row_cap
        super().__init__(f"result exceeds row cap of {row_cap}")


def execute(db_path: Path, sql: str, row_cap: int = ROW_CAP) -> list[tuple]:
    """Execute read-only and return normalized rows."""
    if row_cap <= 0:
        raise ValueError("row_cap must be positive")
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        try:
            cursor = conn.execute(sql)
            rows = cursor.fetchmany(row_cap + 1)
        except sqlite3.Error as error:
            raise ExecutionError(str(error)) from error
        if len(rows) > row_cap:
            raise RowCapExceeded(row_cap)
        return [normalize_row(row) for row in rows]
    finally:
        conn.close()


def normalize_row(row: tuple) -> tuple:
    return tuple(
        round(v, FLOAT_DECIMALS) if isinstance(v, float) else v
        for v in row
    )


def results_match(predicted: list[tuple], gold: list[tuple]) -> bool:
    """Order-insensitive multiset equality."""
    if len(predicted) != len(gold):
        return False
    return Counter(predicted) == Counter(gold)


def score(
    db_path: Path, predicted_sql: str, gold_sql: str, row_cap: int = ROW_CAP
) -> dict:
    """Score one prediction, returning an explicit status for unscorable cases."""
    try:
        gold_rows = execute(db_path, gold_sql, row_cap=row_cap)
    except RowCapExceeded as error:
        return {
            "ex": None,
            "status": "row-cap-exceeded",
            "error": str(error),
            "predicted_rows": None,
            "gold_rows": None,
        }
    except ExecutionError as error:
        return {
            "ex": None,
            "status": "gold-execution-error",
            "error": str(error),
            "predicted_rows": None,
            "gold_rows": None,
        }
    try:
        predicted_rows = execute(db_path, predicted_sql, row_cap=row_cap)
    except RowCapExceeded as error:
        return {
            "ex": None,
            "status": "row-cap-exceeded",
            "error": str(error),
            "predicted_rows": None,
            "gold_rows": len(gold_rows),
        }
    except ExecutionError as error:
        return {
            "ex": False,
            "status": "execution-error",
            "error": str(error),
            "predicted_rows": None,
            "gold_rows": len(gold_rows),
        }
    return {
        "ex": results_match(predicted_rows, gold_rows),
        "status": "scored",
        "error": None,
        "predicted_rows": len(predicted_rows),
        "gold_rows": len(gold_rows),
    }
