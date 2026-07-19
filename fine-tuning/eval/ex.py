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


def execute(db_path: Path, sql: str, row_cap: int = ROW_CAP) -> list[tuple]:
    """Execute read-only and return normalized rows."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        try:
            cursor = conn.execute(sql)
            rows = cursor.fetchmany(row_cap)
        except sqlite3.Error as error:
            raise ExecutionError(str(error)) from error
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


def score(db_path: Path, predicted_sql: str, gold_sql: str) -> dict:
    """Score one prediction. Returns {ex, error, predicted_rows, gold_rows}."""
    gold_rows = execute(db_path, gold_sql)
    try:
        predicted_rows = execute(db_path, predicted_sql)
    except ExecutionError as error:
        return {"ex": False, "error": str(error), "predicted_rows": None, "gold_rows": len(gold_rows)}
    return {
        "ex": results_match(predicted_rows, gold_rows),
        "error": None,
        "predicted_rows": len(predicted_rows),
        "gold_rows": len(gold_rows),
    }
