"""Fail CI when workflow supply-chain safeguards regress."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^\s]+@([0-9a-f]{40})(?:\s+#.*)?$")


def main() -> None:
    failures: list[str] = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        lines = path.read_text().splitlines()
        for number, line in enumerate(lines, start=1):
            if "uses:" in line and not PINNED_ACTION.match(line):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: action is not SHA-pinned"
                )
        for index, line in enumerate(lines):
            if "actions/checkout@" not in line:
                continue
            block = "\n".join(lines[index + 1 : index + 5])
            if "persist-credentials: false" not in block:
                failures.append(
                    f"{path.relative_to(ROOT)}:{index + 1}: checkout persists credentials"
                )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
