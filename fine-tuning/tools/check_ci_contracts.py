"""Fail CI when workflow supply-chain safeguards regress."""

from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^\s]+@([0-9a-f]{40})(?:\s+#.*)?$")
ACCESSIBILITY_CACHE_ACTION = (
    "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
)
ACCESSIBILITY_UPLOAD_ACTION = (
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
)


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


def accessibility_ui_contract_failures(path: Path, workflow: object) -> list[str]:
    prefix = f"{path.relative_to(ROOT)}: accessibility UI contract"
    if not isinstance(workflow, dict):
        return [f"{prefix} requires a workflow mapping"]
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        return [f"{prefix} requires jobs"]
    swift_job = jobs.get("swift")
    if not isinstance(swift_job, dict):
        return [f"{prefix} requires the swift job"]
    steps = swift_job.get("steps")
    if not isinstance(steps, list):
        return [f"{prefix} requires swift job steps"]

    failures: list[str] = []

    def named_step(name: str) -> dict[object, object] | None:
        matches = [
            step
            for step in steps
            if isinstance(step, dict) and step.get("name") == name
        ]
        if len(matches) != 1:
            failures.append(f"{prefix} requires exactly one {name!r} step")
            return None
        return matches[0]

    cache = named_step("Cache Swift and Xcode build artifacts")
    if cache is not None:
        if cache.get("uses") != ACCESSIBILITY_CACHE_ACTION:
            failures.append(f"{prefix} cache action is not pinned to the reviewed SHA")
        inputs = cache.get("with")
        cached_paths = (
            {
                line.strip()
                for line in inputs.get("path", "").splitlines()
                if line.strip()
            }
            if isinstance(inputs, dict) and isinstance(inputs.get("path"), str)
            else set()
        )
        required_paths = {
            "CREGKit/.build",
            "${{ runner.temp }}/creg-derived-data",
            "${{ runner.temp }}/creg-source-packages",
        }
        missing_paths = sorted(required_paths - cached_paths)
        if missing_paths:
            failures.append(
                f"{prefix} cache step is missing paths: " + ", ".join(missing_paths)
            )

    ui_test = named_step("Test focused accessibility UI contracts")
    if ui_test is not None:
        if ui_test.get("timeout-minutes") != 30:
            failures.append(f"{prefix} UI test timeout must be 30 minutes")
        run = ui_test.get("run")
        required_command_fragments = (
            "xcodebuild test",
            "name=iPhone 17 Pro,OS=26.5",
            '-clonedSourcePackagesDirPath "${RUNNER_TEMP}/creg-source-packages"',
            '-derivedDataPath "${RUNNER_TEMP}/creg-derived-data"',
            '-resultBundlePath "${RUNNER_TEMP}/creg-accessibility-ui-tests.xcresult"',
            "-skipPackagePluginValidation",
            (
                "-only-testing:CREGUITests/AccessibilityUITests/"
                "testHighestRiskScreensAtAX5Landscape"
            ),
            (
                "-only-testing:CREGUITests/AccessibilityUITests/"
                "testMalformedConfigurationRendersInvalidConfigurationScreen"
            ),
            (
                "-only-testing:CREGUITests/AccessibilityUITests/"
                "testChartPreparationHasDistinctIdentityInProductionPresentation"
            ),
            "CREG_ACCESSIBILITY_HARNESS_BUILD=YES",
        )
        if not isinstance(run, str):
            failures.append(f"{prefix} UI test step must contain a shell command")
        else:
            missing_fragments = [
                fragment
                for fragment in required_command_fragments
                if fragment not in run
            ]
            if missing_fragments:
                failures.append(
                    f"{prefix} UI test step is missing command fragments: "
                    + ", ".join(missing_fragments)
                )

    upload = named_step("Upload accessibility UI test results")
    if upload is not None:
        if upload.get("uses") != ACCESSIBILITY_UPLOAD_ACTION:
            failures.append(f"{prefix} upload action is not pinned to the reviewed SHA")
        if upload.get("if") != "${{ always() }}":
            failures.append(f"{prefix} result upload must run even after test failure")
        inputs = upload.get("with")
        if not isinstance(inputs, dict) or inputs.get("path") != (
            "${{ runner.temp }}/creg-accessibility-ui-tests.xcresult"
        ):
            failures.append(f"{prefix} result upload path is incorrect")

    return failures


def main() -> None:
    failures: list[str] = []
    workflow_paths = sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")))
    for path in workflow_paths:
        source = path.read_text()
        lines = source.splitlines()
        for number, line in enumerate(lines, start=1):
            if "uses:" in line and not PINNED_ACTION.match(line):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: action is not SHA-pinned"
                )
        workflow = yaml.safe_load(source)
        failures.extend(checkout_credential_failures(path, workflow))
        if path.name == "ci.yml":
            failures.extend(accessibility_ui_contract_failures(path, workflow))
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
