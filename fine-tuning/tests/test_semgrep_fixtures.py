import json
from io import StringIO

import pytest

from tools import check_semgrep_fixtures


RULE = "creg-shell-contracts-require-structured-validation"


def finding(path, line):
    return {"path": str(path), "check_id": RULE, "start": {"line": line}}


def run_checker(monkeypatch, arguments, payload):
    monkeypatch.setattr(
        check_semgrep_fixtures.sys,
        "argv",
        ["check_semgrep_fixtures.py", *map(str, arguments)],
    )
    monkeypatch.setattr(
        check_semgrep_fixtures.sys,
        "stdin",
        StringIO(json.dumps(payload)),
    )
    check_semgrep_fixtures.main()


def test_directory_argument_discovers_new_annotated_fixture(tmp_path, monkeypatch):
    fixture = tmp_path / "new-fixture.py"
    fixture.write_text(f"# ruleid: {RULE}\nunsafe()\n")

    run_checker(monkeypatch, [tmp_path], {"results": [finding(fixture, 2)]})


def test_finding_from_an_unlisted_scanned_file_is_not_discarded(
    tmp_path, monkeypatch
):
    listed = tmp_path / "listed.py"
    listed.write_text(f"# ruleid: {RULE}\nunsafe()\n")
    unlisted = tmp_path / "unlisted.py"
    unlisted.write_text("unsafe()\n")

    with pytest.raises(SystemExit, match="Semgrep fixture mismatch"):
        run_checker(
            monkeypatch,
            [listed],
            {"results": [finding(listed, 2), finding(unlisted, 1)]},
        )
