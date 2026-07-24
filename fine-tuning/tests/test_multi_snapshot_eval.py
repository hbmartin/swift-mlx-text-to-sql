import json
import sqlite3
from pathlib import Path

from eval.ex import score
from eval.run_eval import database_set_identity
from eval.run_artifacts import REPO_ROOT, sha256_file
from tools.generate_eval_snapshots import BASE_DATABASE, generate


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


def test_committed_counterexample_snapshots_regenerate_byte_identically(tmp_path):
    regenerated = generate(BASE_DATABASE, tmp_path)
    committed = json.loads((REPO_ROOT / "eval/snapshots/manifest.json").read_text())
    assert regenerated["base"]["sha256"] == committed["base"]["sha256"]
    assert [item["sha256"] for item in regenerated["snapshots"]] == [
        item["sha256"] for item in committed["snapshots"]
    ]
    for item in committed["snapshots"]:
        assert sha256_file(REPO_ROOT / item["path"]) == item["sha256"]
