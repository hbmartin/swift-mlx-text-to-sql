"""Fail CI when workflow supply-chain safeguards regress."""

from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^\s]+@([0-9a-f]{40})(?:\s+#.*)?$")


def checkout_credential_failures(path: Path, workflow: object) -> list[str]:
    if not isinstance(workflow, dict):
        return [f"{path.relative_to(ROOT)}: workflow must be a mapping"]
    jobs = workflow.get("jobs", {})
    if not isinstance(jobs, dict):
        return [f"{path.relative_to(ROOT)}: jobs must be a mapping"]

    failures = []
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            continue
        for step_number, step in enumerate(steps, start=1):
            if not isinstance(step, dict):
                continue
            uses = step.get("uses")
            if not isinstance(uses, str) or not uses.startswith("actions/checkout@"):
                continue
            inputs = step.get("with")
            if (
                not isinstance(inputs, dict)
                or inputs.get("persist-credentials") is not False
            ):
                failures.append(
                    f"{path.relative_to(ROOT)}: job {job_name} checkout step "
                    f"{step_number} persists credentials"
                )
    return failures


def main() -> None:
    failures: list[str] = []
    workflow_paths = sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")))
    for path in workflow_paths:
        lines = path.read_text().splitlines()
        for number, line in enumerate(lines, start=1):
            if "uses:" in line and not PINNED_ACTION.match(line):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: action is not SHA-pinned"
                )
        failures.extend(
            checkout_credential_failures(path, yaml.safe_load(path.read_text()))
        )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
