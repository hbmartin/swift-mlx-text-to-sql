"""Verify that Semgrep findings agree with inline ruleid and ok annotations."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ANNOTATION = re.compile(r"(?:#|//)\s*(ruleid|ok):\s*([a-z0-9-]+)\s*$")
Finding = tuple[Path, str, int]


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


def main() -> None:
    fixtures = tuple(Path(argument) for argument in sys.argv[1:])
    if not fixtures:
        raise SystemExit("usage: check_semgrep_fixtures.py FIXTURE [FIXTURE ...]")
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
        if Path(result["path"]) in fixtures
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
