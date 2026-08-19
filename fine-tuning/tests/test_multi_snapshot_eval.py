import json
import sqlite3
from pathlib import Path

import pytest

from eval.ex import score
from eval.run_eval import canonicalize_database_inputs, database_set_identity
from eval.run_artifacts import REPO_ROOT, sha256_file
from tools.generate_eval_snapshots import (
    BASE_DATABASE,
    SQLITE_HEADER,
    SQLITE_VERSION_NUMBER_OFFSET,
    SQLITE_VERSION_NUMBER_SIZE,
    generate,
    materialize_snapshot,
    read_canonical_version_number,
    write_sqlite_version_number,
)

VERSION_NUMBER_SLICE = slice(
    SQLITE_VERSION_NUMBER_OFFSET,
    SQLITE_VERSION_NUMBER_OFFSET + SQLITE_VERSION_NUMBER_SIZE,
)
# No SQLite library reports version 1, so a snapshot carrying this value can
# only have been stamped from the base rather than left as the host wrote it.
SENTINEL_VERSION_NUMBER = b"\x00\x00\x00\x01"


def database(path: Path, values: tuple[int, ...]) -> None:
    connection = sqlite3.connect(path)
    try:
        connection.execute("CREATE TABLE values_table(value INTEGER NOT NULL)")
        connection.executemany(
            "INSERT INTO values_table(value) VALUES (?)",
            ((value,) for value in values),
        )
        connection.commit()
    finally:
        connection.close()


def test_second_snapshot_exposes_coincidentally_equivalent_sql(tmp_path):
    first = tmp_path / "first.sqlite"
    second = tmp_path / "second.sqlite"
    database(first, (1, 2))
    database(second, (1, 2, 3))
    gold = "SELECT value FROM values_table"
    candidate = "SELECT value FROM values_table WHERE value < 3"
    assert score(first, candidate, gold)["ex"] is True
    assert score(second, candidate, gold)["ex"] is False


def test_database_set_identity_is_independent_of_argument_order():
    first = {"sha256": "a" * 64}
    second = {"sha256": "b" * 64}
    assert database_set_identity([first, second]) == database_set_identity(
        [second, first]
    )
    assert database_set_identity([first, second]) != database_set_identity([first])


def test_database_paths_and_inputs_are_canonicalized_as_pairs(tmp_path):
    first = tmp_path / "first.sqlite"
    second = tmp_path / "second.sqlite"
    database(first, (1, 2))
    database(second, (1, 2, 3))

    forward = canonicalize_database_inputs((first.resolve(), second.resolve()))
    reversed_order = canonicalize_database_inputs(
        (second.resolve(), first.resolve())
    )

    assert forward == reversed_order
    paths, inputs = forward
    assert [record["path"] for record in inputs] == [str(path) for path in paths]


def stamp_version_number(path: Path, version_number: bytes) -> None:
    contents = bytearray(path.read_bytes())
    contents[VERSION_NUMBER_SLICE] = version_number
    path.write_bytes(bytes(contents))


def test_sqlite_version_number_is_canonicalized_from_base(tmp_path):
    base = tmp_path / "base.sqlite"
    snapshot = tmp_path / "snapshot.sqlite"
    minimum_size = SQLITE_VERSION_NUMBER_OFFSET + SQLITE_VERSION_NUMBER_SIZE
    base_bytes = bytearray(minimum_size)
    snapshot_bytes = bytearray(minimum_size)
    base_bytes[: len(SQLITE_HEADER)] = SQLITE_HEADER
    snapshot_bytes[: len(SQLITE_HEADER)] = SQLITE_HEADER
    base_bytes[VERSION_NUMBER_SLICE] = b"\x01\x02\x03\x04"
    snapshot_bytes[VERSION_NUMBER_SLICE] = b"\x05\x06\x07\x08"
    base.write_bytes(base_bytes)
    snapshot.write_bytes(snapshot_bytes)

    write_sqlite_version_number(snapshot, read_canonical_version_number(base))

    assert (
        snapshot.read_bytes()[VERSION_NUMBER_SLICE]
        == base_bytes[VERSION_NUMBER_SLICE]
    )


def test_version_number_of_the_wrong_width_is_rejected(tmp_path):
    snapshot = tmp_path / "snapshot.sqlite"
    contents = bytearray(SQLITE_VERSION_NUMBER_OFFSET + SQLITE_VERSION_NUMBER_SIZE)
    contents[: len(SQLITE_HEADER)] = SQLITE_HEADER
    snapshot.write_bytes(bytes(contents))

    with pytest.raises(RuntimeError, match="exactly"):
        write_sqlite_version_number(snapshot, b"\x01\x02\x03")

    assert snapshot.read_bytes() == bytes(contents)


def test_materialized_snapshot_is_stamped_with_the_base_version_number(tmp_path):
    """Cover the stamp on the path that actually ships snapshots.

    ``materialize_snapshot`` writes through SQLite, which rewrites the header
    version number with the host library's own value, so this fails if the
    stamp is dropped from the materialization path rather than only if the
    stamping helpers themselves regress.
    """

    base = tmp_path / "base.sqlite"
    destination = tmp_path / "snapshots" / "stamped.sqlite"
    database(base, (1, 2))
    stamp_version_number(base, SENTINEL_VERSION_NUMBER)

    def mutation(connection: sqlite3.Connection) -> None:
        connection.execute("INSERT INTO values_table(value) VALUES (3)")

    version_number = read_canonical_version_number(base)
    assert version_number == SENTINEL_VERSION_NUMBER

    materialize_snapshot(base, destination, mutation, version_number)

    assert destination.read_bytes()[VERSION_NUMBER_SLICE] == SENTINEL_VERSION_NUMBER


def test_committed_counterexample_snapshots_regenerate_byte_identically(tmp_path):
    regenerated = generate(BASE_DATABASE, tmp_path)
    committed = json.loads((REPO_ROOT / "eval/snapshots/manifest.json").read_text())
    assert regenerated["base"]["sha256"] == committed["base"]["sha256"]
    assert [item["sha256"] for item in regenerated["snapshots"]] == [
        item["sha256"] for item in committed["snapshots"]
    ]
    for item in committed["snapshots"]:
        assert sha256_file(REPO_ROOT / item["path"]) == item["sha256"]
