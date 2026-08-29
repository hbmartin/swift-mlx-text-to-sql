"""Verify that Semgrep findings agree with inline ruleid and ok annotations."""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path


ANNOTATION = re.compile(r"(?:#|//)\s*(ruleid|ok):\s*([a-z0-9-]+)\s*$")
Finding = tuple[Path, str, int]
FIXTURE_SUFFIXES = {".py", ".swift"}


def annotated_findings(path: Path) -> tuple[set[Finding], set[Finding]]:
    required: set[Finding] = set()
    forbidden: set[Finding] = set()
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        match = ANNOTATION.search(line)
        if match is None:
            continue
        finding = (path, match.group(2), line_number + 1)
        (required if match.group(1) == "ruleid" else forbidden).add(finding)
    return required, forbidden


def fixture_paths(arguments: Sequence[str]) -> tuple[Path, ...]:
    fixtures: set[Path] = set()
    for argument in arguments:
        path = Path(argument)
        if not path.exists():
            raise ValueError(f"fixture path does not exist: {path}")
        if path.is_dir():
            fixtures.update(
                candidate
                for candidate in path.rglob("*")
                if candidate.is_file() and candidate.suffix in FIXTURE_SUFFIXES
            )
        else:
            if not path.is_file():
                raise ValueError(f"fixture path is not a file or directory: {path}")
            if path.suffix not in FIXTURE_SUFFIXES:
                raise ValueError(f"unsupported fixture file type: {path}")
            fixtures.add(path)
    return tuple(sorted(fixtures))


def main() -> None:
    try:
        fixtures = fixture_paths(sys.argv[1:])
    except ValueError as error:
        raise SystemExit(f"Semgrep fixture argument error: {error}") from error
    if not fixtures:
        raise SystemExit("usage: check_semgrep_fixtures.py FIXTURE_OR_DIRECTORY [...]")
    required: set[Finding] = set()
    forbidden: set[Finding] = set()
    for fixture in fixtures:
        fixture_required, fixture_forbidden = annotated_findings(fixture)
        required.update(fixture_required)
        forbidden.update(fixture_forbidden)
    payload = json.load(sys.stdin)
    actual = {
        (Path(result["path"]), result["check_id"], result["start"]["line"])
        for result in payload.get("results", [])
    }
    errors = payload.get("errors", [])
    if errors or actual != required or actual & forbidden:
        raise SystemExit(
            "Semgrep fixture mismatch: "
            f"required={sorted(required)}, forbidden={sorted(forbidden)}, "
            f"actual={sorted(actual)}, errors={errors}"
        )


if __name__ == "__main__":
    main()
