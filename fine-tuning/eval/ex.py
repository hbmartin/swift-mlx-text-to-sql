"""Typed execution-accuracy (EX) scoring.

EX is order-insensitive multiset equality over result rows. Values remain in
separate SQLite type domains except that INTEGER and REAL intentionally share
one numeric domain after four-decimal, half-even normalization.
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
import sqlite3
import time
from collections import Counter
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_EVEN
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

ROW_CAP = 10_000
FLOAT_DECIMALS = 4
FLOAT_QUANTUM = Decimal("0.0001")

CanonicalValue = tuple[str, str]
CanonicalRow = tuple[CanonicalValue, ...]
DOMAIN_ORDER = {"null": 0, "number": 1, "text": 2, "blob": 3}


class ExecutionError(Exception):
    pass


@dataclass(frozen=True)
class QueryExecution(Sequence[tuple[Any, ...]]):
    """Rows plus the information needed to reject a capped comparison."""

    rows: tuple[tuple[Any, ...], ...]
    is_truncated: bool = False
    elapsed_microseconds: int = 0

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index):
        return self.rows[index]

    def __iter__(self) -> Iterator[tuple[Any, ...]]:
        return iter(self.rows)


def canonical_number(value: int | float) -> str:
    if isinstance(value, bool):
        value = int(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("SQLite EX does not support non-finite REAL values")
        decimal = Decimal(str(value)).quantize(FLOAT_QUANTUM, rounding=ROUND_HALF_EVEN)
    else:
        decimal = Decimal(value)
    if decimal == 0:
        return "0"
    rendered = format(decimal, "f")
    if "." in rendered:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered


def canonical_value(value: Any) -> CanonicalValue:
    if value is None:
        return ("null", "")
    if isinstance(value, (int, float)):
        return ("number", canonical_number(value))
    if isinstance(value, str):
        return ("text", value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        encoded = base64.b64encode(bytes(value)).decode("ascii")
        return ("blob", encoded)
    raise TypeError(f"unsupported SQLite result value: {type(value).__name__}")


def canonical_row(row: Iterable[Any]) -> CanonicalRow:
    return tuple(canonical_value(value) for value in row)


def canonical_rows(rows: Iterable[Iterable[Any]]) -> tuple[CanonicalRow, ...]:
    def row_key(row: CanonicalRow) -> tuple[tuple[int, str], ...]:
        return tuple((DOMAIN_ORDER[kind], value) for kind, value in row)

    return tuple(sorted((canonical_row(row) for row in rows), key=row_key))


def typed_rows(rows: Iterable[Iterable[Any]]) -> list[list[dict[str, str]]]:
    """Stable JSON representation used by run artifacts and parity fixtures."""
    return [
        [{"type": kind, "value": value} for kind, value in row]
        for row in canonical_rows(rows)
    ]


def result_digest(rows: Iterable[Iterable[Any]]) -> str:
    payload = json.dumps(
        typed_rows(rows),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def normalize_row(row: tuple[Any, ...]) -> tuple[Any, ...]:
    """Normalize REAL presentation while retaining SQLite type information."""
    normalized: list[Any] = []
    for value in row:
        if isinstance(value, float):
            normalized.append(float(canonical_number(value)))
        else:
            normalized.append(value)
    return tuple(normalized)


def execute_with_metadata(
    db_path: Path, sql: str, row_cap: int = ROW_CAP
) -> QueryExecution:
    """Execute read-only and fetch one extra row to detect truncation."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        started_ns = time.perf_counter_ns()
        try:
            cursor = conn.execute(sql)
            fetched = cursor.fetchmany(row_cap + 1)
        except sqlite3.Error as error:
            raise ExecutionError(str(error)) from error
        is_truncated = len(fetched) > row_cap
        rows = tuple(normalize_row(row) for row in fetched[:row_cap])
        return QueryExecution(
            rows=rows,
            is_truncated=is_truncated,
            elapsed_microseconds=(time.perf_counter_ns() - started_ns) // 1_000,
        )
    finally:
        conn.close()


def execute(db_path: Path, sql: str, row_cap: int = ROW_CAP) -> list[tuple[Any, ...]]:
    """Compatibility wrapper returning rows while metadata-aware callers use
    ``execute_with_metadata``.
    """
    return list(execute_with_metadata(db_path, sql, row_cap).rows)


def results_match(
    predicted: Sequence[tuple[Any, ...]] | QueryExecution,
    gold: Sequence[tuple[Any, ...]] | QueryExecution,
) -> bool:
    """Order-insensitive, typed multiset equality."""
    if isinstance(predicted, QueryExecution) and predicted.is_truncated:
        return False
    if isinstance(gold, QueryExecution) and gold.is_truncated:
        return False
    if len(predicted) != len(gold):
        return False
    return Counter(canonical_row(row) for row in predicted) == Counter(
        canonical_row(row) for row in gold
    )


def score(db_path: Path, predicted_sql: str, gold_sql: str) -> dict[str, Any]:
    """Score one prediction with explicit truncation metadata."""
    gold = execute_with_metadata(db_path, gold_sql)
    try:
        predicted = execute_with_metadata(db_path, predicted_sql)
    except ExecutionError as error:
        return {
            "ex": False,
            "error": str(error),
            "predicted_rows": None,
            "gold_rows": len(gold),
            "predicted_truncated": None,
            "gold_truncated": gold.is_truncated,
        }
    return {
        "ex": results_match(predicted, gold),
        "error": None,
        "predicted_rows": len(predicted),
        "gold_rows": len(gold),
        "predicted_truncated": predicted.is_truncated,
        "gold_truncated": gold.is_truncated,
    }
