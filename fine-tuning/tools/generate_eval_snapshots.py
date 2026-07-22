"""Materialize deterministic counterexample SQLite snapshots for evaluation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path
from typing import Callable

from eval.run_artifacts import REPO_ROOT


BASE_DATABASE = REPO_ROOT / "db" / "creg.sqlite"
OUTPUT_DIRECTORY = REPO_ROOT / "eval" / "snapshots"
Mutation = Callable[[sqlite3.Connection], None]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stagger_latest_and_add_tie(connection: sqlite3.Connection) -> None:
    property_ids = [
        row[0]
        for row in connection.execute(
            "SELECT DISTINCT property_id FROM property_financials ORDER BY property_id LIMIT 2"
        )
    ]
    if len(property_ids) != 2:
        raise RuntimeError("base database lacks two financial properties")
    next_id = connection.execute(
        "SELECT MAX(financial_id) + 1 FROM property_financials"
    ).fetchone()[0]
    first, second = property_ids
    connection.execute(
        """
        INSERT INTO property_financials(
            financial_id, property_id, period_end, period_type,
            gross_potential_rent, vacancy_loss, effective_gross_income,
            operating_expenses, net_operating_income, capex, debt_service,
            occupancy_rate
        )
        SELECT ?, property_id, '2026-07-31', period_type,
               gross_potential_rent, vacancy_loss, effective_gross_income,
               operating_expenses, net_operating_income, capex, debt_service,
               0.731
        FROM property_financials
        WHERE property_id = ?
        ORDER BY period_end DESC LIMIT 1
        """,
        (next_id, first),
    )
    connection.execute(
        """
        INSERT INTO property_financials(
            financial_id, property_id, period_end, period_type,
            gross_potential_rent, vacancy_loss, effective_gross_income,
            operating_expenses, net_operating_income, capex, debt_service,
            occupancy_rate
        )
        SELECT ?, property_id, period_end, period_type,
               gross_potential_rent, vacancy_loss, effective_gross_income,
               operating_expenses, net_operating_income, capex, debt_service,
               NULL
        FROM property_financials
        WHERE property_id = ?
        ORDER BY period_end DESC LIMIT 1
        """,
        (next_id + 1, second),
    )


def change_portfolio_boundaries(connection: sqlite3.Connection) -> None:
    sold = connection.execute(
        "SELECT property_id FROM properties WHERE status = 'Sold' ORDER BY property_id LIMIT 1"
    ).fetchone()
    owned = connection.execute(
        "SELECT property_id FROM properties WHERE status = 'Owned' ORDER BY property_id DESC LIMIT 1"
    ).fetchone()
    if sold is None or owned is None:
        raise RuntimeError("base database lacks sold/owned boundary cases")
    connection.execute(
        "UPDATE properties SET status = 'Under Contract', disposition_date = NULL WHERE property_id = ?",
        sold,
    )
    connection.execute(
        "UPDATE properties SET status = 'Under Contract' WHERE property_id = ?",
        owned,
    )


SNAPSHOTS: tuple[tuple[str, str, Mutation], ...] = (
    (
        "latest-staggered.sqlite",
        "one property reports later than the rest; another has tied latest rows including NULL",
        stagger_latest_and_add_tie,
    ),
    (
        "portfolio-boundaries.sqlite",
        "sold and owned records move to Under Contract to distinguish held from owned-only",
        change_portfolio_boundaries,
    ),
)


def materialize_snapshot(base: Path, destination: Path, mutation: Mutation) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    os.close(descriptor)
    staged = Path(temporary_name)
    try:
        shutil.copy2(base, staged)
        connection = sqlite3.connect(staged)
        try:
            mutation(connection)
            connection.commit()
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            if integrity != "ok":
                raise RuntimeError(f"snapshot integrity check failed: {integrity}")
        finally:
            connection.close()
        os.replace(staged, destination)
    finally:
        if staged.exists():
            staged.unlink()


def generate(base: Path, output_directory: Path) -> dict:
    if base.is_symlink() or not base.is_file():
        raise RuntimeError(f"base database must be a regular file: {base}")
    records = []
    for filename, purpose, mutation in SNAPSHOTS:
        destination = output_directory / filename
        materialize_snapshot(base, destination, mutation)
        records.append(
            {
                "path": destination.relative_to(REPO_ROOT).as_posix()
                if destination.is_relative_to(REPO_ROOT)
                else str(destination),
                "sha256": sha256_file(destination),
                "size": destination.stat().st_size,
                "purpose": purpose,
            }
        )
    manifest = {
        "schema_version": 1,
        "base": {
            "path": base.relative_to(REPO_ROOT).as_posix()
            if base.is_relative_to(REPO_ROOT)
            else str(base),
            "sha256": sha256_file(base),
            "size": base.stat().st_size,
        },
        "snapshots": records,
    }
    manifest_path = output_directory / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=BASE_DATABASE)
    parser.add_argument("--out-dir", type=Path, default=OUTPUT_DIRECTORY)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest = generate(args.base.resolve(), args.out_dir.resolve())
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
