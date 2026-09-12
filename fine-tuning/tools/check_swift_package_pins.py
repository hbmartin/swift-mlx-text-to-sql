"""Verify that CREG's checked-in AutoTableCharts revisions agree."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path("CREGKit/Package.swift")
RESOLUTIONS = (
    Path("CREGKit/Package.resolved"),
    Path("CREG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)
MANIFEST_PIN = re.compile(
    r"\.package\(\s*"
    r'url:\s*"https://github\.com/hbmartin/AutoTableCharts\.git",\s*'
    r'revision:\s*"([0-9a-f]{40})"\s*\)',
    re.MULTILINE,
)


def manifest_revision(path: Path) -> str:
    match = MANIFEST_PIN.search(path.read_text())
    if match is None:
        raise ValueError(f"{path}: missing exact AutoTableCharts revision")
    return match.group(1)


def resolved_revision(path: Path) -> str:
    payload = json.loads(path.read_text())
    matches = [
        pin["state"]["revision"]
        for pin in payload.get("pins", [])
        if pin.get("identity") == "autotablecharts"
    ]
    if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{40}", matches[0]):
        raise ValueError(f"{path}: expected one exact AutoTableCharts revision")
    return matches[0]


def pin_failures(root: Path = ROOT) -> list[str]:
    expected = manifest_revision(root / MANIFEST)
    failures = []
    for relative_path in RESOLUTIONS:
        actual = resolved_revision(root / relative_path)
        if actual != expected:
            failures.append(
                f"{relative_path}: AutoTableCharts resolves to {actual}; "
                f"{MANIFEST} requires {expected}"
            )
    return failures


def main() -> int:
    try:
        failures = pin_failures()
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
