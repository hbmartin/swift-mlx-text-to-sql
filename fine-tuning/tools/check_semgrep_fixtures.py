"""Verify that Semgrep findings agree with inline ruleid and ok annotations."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ANNOTATION = re.compile(r"(?:#|//)\s*(ruleid|ok):\s*([a-z0-9-]+)\s*$")


def annotated_findings(path: Path) -> tuple[set[tuple[str, int]], set[tuple[str, int]]]:
    required: set[tuple[str, int]] = set()
    forbidden: set[tuple[str, int]] = set()
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        match = ANNOTATION.search(line)
        if match is None:
            continue
        finding = (match.group(2), line_number + 1)
        (required if match.group(1) == "ruleid" else forbidden).add(finding)
    return required, forbidden


def main() -> None:
    fixture = Path(sys.argv[1])
    required, forbidden = annotated_findings(fixture)
    payload = json.load(sys.stdin)
    actual = {
        (result["check_id"], result["start"]["line"])
        for result in payload.get("results", [])
        if Path(result["path"]) == fixture
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
