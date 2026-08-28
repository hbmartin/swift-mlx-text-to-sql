"""Fail CI when workflow supply-chain safeguards regress."""

from __future__ import annotations

import re
import shlex
from collections.abc import Sequence
from dataclasses import dataclass
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
ACCESSIBILITY_WORKFLOW_NAME = "CI"
ACCESSIBILITY_UI_TEST_COMMAND = (
    "xcodebuild",
    "test",
    "-project",
    "CREG.xcodeproj",
    "-scheme",
    "CREG",
    "-destination",
    "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
    "-clonedSourcePackagesDirPath",
    "${RUNNER_TEMP}/creg-source-packages",
    "-derivedDataPath",
    "${RUNNER_TEMP}/creg-derived-data",
    "-resultBundlePath",
    "${RUNNER_TEMP}/creg-accessibility-ui-tests.xcresult",
    "-skipPackagePluginValidation",
    "-skipMacroValidation",
    "-only-testing:CREGUITests/AccessibilityUITests/"
    "testHighestRiskScreensAtAX5Landscape",
    "-only-testing:CREGUITests/AccessibilityUITests/"
    "testMalformedConfigurationRendersInvalidConfigurationScreen",
    "-only-testing:CREGUITests/AccessibilityUITests/"
    "testChartPreparationHasDistinctIdentityInProductionPresentation",
    "CREG_ACCESSIBILITY_HARNESS_BUILD=YES",
)
ACCESSIBILITY_UI_DOUBLE_QUOTED_FLAGS = (
    "-clonedSourcePackagesDirPath",
    "-derivedDataPath",
    "-resultBundlePath",
)
TESTFLIGHT_PUBLISHER_TEST_COMMAND = (
    "uv",
    "run",
    "--no-project",
    "--managed-python",
    "--python",
    "3.13",
    "python",
    "-m",
    "unittest",
    "discover",
    "-s",
    ".agents/skills/publish-creg-testflight/tests",
    "-p",
    "test_*.py",
)
LoadedWorkflow = tuple[Path, str, object]


@dataclass(frozen=True)
class ParsedShellCommand:
    tokens: tuple[str, ...]
    single_quoted_values: tuple[str, ...]
    double_quoted_values: tuple[str, ...]


def load_workflows(directory: Path | None = None) -> list[LoadedWorkflow]:
    workflow_directory = WORKFLOWS if directory is None else directory
    paths = sorted(
        (*workflow_directory.glob("*.yml"), *workflow_directory.glob("*.yaml"))
    )
    workflows = []
    for path in paths:
        source = path.read_text()
        workflows.append((path, source, yaml.safe_load(source)))
    return workflows


def display_path(path: Path, root: Path | None = None) -> str:
    effective_root = ROOT if root is None else root
    try:
        relative = path.relative_to(effective_root)
    except ValueError:
        return str(path)
    return str(path) if relative == Path(".") else str(relative)


def _parse_single_shell_command(source: str) -> ParsedShellCommand:
    """Parse the deliberately restricted shell grammar allowed in CI."""
    normalized_parts: list[str] = []
    single_quoted_values: list[str] = []
    double_quoted_values: list[str] = []
    quoted_parts: list[str] | None = None
    quote: str | None = None
    in_comment = False
    at_word_start = True
    index = 0
    source = source.strip(" \t\r\n")
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else None
        if character == "\\" and following == "\n":
            continuation_length = 2
        else:
            continuation_length = 0

        if in_comment:
            if character in "\r\n":
                # Shell comments always end at the physical newline. A
                # backslash inside the comment does not continue it.
                raise ValueError("must contain exactly one shell command")
            index += 1
            continue

        if quote == "'":
            normalized_parts.append(character)
            if character == "'":
                assert quoted_parts is not None
                single_quoted_values.append("".join(quoted_parts))
                quoted_parts = None
                quote = None
            else:
                assert quoted_parts is not None
                quoted_parts.append(character)
            index += 1
            continue

        if quote == '"':
            if continuation_length:
                index += continuation_length
                continue
            if character == "\\" and following is not None:
                normalized_parts.extend((character, following))
                assert quoted_parts is not None
                quoted_parts.extend((character, following))
                index += 2
                continue
            assert quoted_parts is not None
            escaped_dollar = False
            if character == "(" and quoted_parts[-1:] == ["$"]:
                preceding_backslashes = 0
                for part in reversed(quoted_parts[:-1]):
                    if part != "\\":
                        break
                    preceding_backslashes += 1
                escaped_dollar = preceding_backslashes % 2 == 1
            continued_substitution = (
                character == "("
                and not escaped_dollar
                and quoted_parts[-1:] == ["$"]
            )
            if (
                character == "`"
                or (character == "$" and following == "(")
                or continued_substitution
            ):
                raise ValueError("must not contain shell command substitutions")
            normalized_parts.append(character)
            if character == '"':
                double_quoted_values.append("".join(quoted_parts))
                quoted_parts = None
                quote = None
            else:
                quoted_parts.append(character)
            index += 1
            continue

        if continuation_length:
            index += continuation_length
            continue

        if character == "\\" and following is not None:
            normalized_parts.extend((character, following))
            at_word_start = False
            index += 2
            continue
        if character in "'\"":
            normalized_parts.append(character)
            quote = character
            quoted_parts = []
            at_word_start = False
            index += 1
            continue
        if character == "#" and at_word_start:
            in_comment = True
            index += 1
            continue
        if character in "\r\n":
            raise ValueError("must contain exactly one shell command")
        if character == "`" or (character == "$" and following == "("):
            raise ValueError("must not contain shell command substitutions")
        if character in "<>":
            raise ValueError("must not contain shell redirections")
        if character in ";&|()":
            raise ValueError("must not contain shell control operators")
        normalized_parts.append(character)
        at_word_start = character in " \t\r\n"
        index += 1

    normalized = "".join(normalized_parts).strip(" \t\r\n")
    tokens = tuple(shlex.split(normalized, comments=False, posix=True))
    return ParsedShellCommand(
        tokens=tokens,
        single_quoted_values=tuple(single_quoted_values),
        double_quoted_values=tuple(double_quoted_values),
    )


def workflow_job_steps(
    workflow: object,
    *,
    job_name: str,
    prefix: str,
) -> tuple[dict[object, object] | None, list[object] | None, list[str]]:
    if not isinstance(workflow, dict):
        return None, None, [f"{prefix} requires a workflow mapping"]
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        return None, None, [f"{prefix} requires jobs"]
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        return None, None, [f"{prefix} requires the {job_name} job"]
    steps = job.get("steps")
    if not isinstance(steps, list):
        return None, None, [f"{prefix} requires {job_name} job steps"]
    return job, steps, []


def reviewed_run_context_failures(
    workflow: object,
    job: dict[object, object],
    step: dict[object, object],
    *,
    job_name: str,
    step_name: str,
    prefix: str,
) -> list[str]:
    """Reject metadata that can skip or reinterpret a reviewed run step."""
    assert isinstance(workflow, dict)
    failures: list[str] = []
    workflow_fields = [
        field for field in ("defaults", "env") if field in workflow
    ]
    if workflow_fields:
        failures.append(
            f"{prefix} workflow must not override reviewed run context: "
            + ", ".join(workflow_fields)
        )
    job_fields = [
        field
        for field in (
            "continue-on-error",
            "defaults",
            "env",
            "if",
            "needs",
            "strategy",
        )
        if field in job
    ]
    if job_fields:
        failures.append(
            f"{prefix} {job_name} job must not override reviewed run context: "
            + ", ".join(job_fields)
        )
    if job.get("runs-on") != "macos-26":
        failures.append(f"{prefix} {job_name} job must run on macos-26")
    step_fields = [
        field
        for field in (
            "continue-on-error",
            "env",
            "if",
            "shell",
            "working-directory",
        )
        if field in step
    ]
    if step_fields:
        failures.append(
            f"{prefix} {step_name!r} step must not override reviewed run context: "
            + ", ".join(step_fields)
        )
    return failures


def named_step(
    steps: Sequence[object],
    *,
    name: str,
    prefix: str,
) -> tuple[dict[object, object] | None, list[str]]:
    matches = [
        step
        for step in steps
        if isinstance(step, dict) and step.get("name") == name
    ]
    if len(matches) != 1:
        return None, [f"{prefix} requires exactly one {name!r} step"]
    return matches[0], []


def exact_command_mismatch(
    command_tokens: Sequence[str], expected_tokens: Sequence[str]
) -> str | None:
    for index, (actual, expected) in enumerate(
        zip(command_tokens, expected_tokens, strict=False), start=1
    ):
        if actual != expected:
            return f"token {index} must be {expected!r}, found {actual!r}"
    if len(command_tokens) < len(expected_tokens):
        return (
            f"missing token {len(command_tokens) + 1}: "
            f"expected {expected_tokens[len(command_tokens)]!r}"
        )
    if len(command_tokens) > len(expected_tokens):
        return (
            f"unexpected token {len(expected_tokens) + 1}: "
            f"{command_tokens[len(expected_tokens)]!r}"
        )
    return None


def accessibility_workflows(
    workflows: Sequence[LoadedWorkflow] | None = None,
) -> list[tuple[Path, object]]:
    loaded = load_workflows() if workflows is None else workflows
    return [
        (path, workflow)
        for path, _, workflow in loaded
        if isinstance(workflow, dict)
        and workflow.get("name") == ACCESSIBILITY_WORKFLOW_NAME
    ]


def checkout_credential_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    displayed_path = display_path(path, root)
    if not isinstance(workflow, dict):
        return [f"{displayed_path}: workflow must be a mapping"]
    jobs = workflow.get("jobs", {})
    if not isinstance(jobs, dict):
        return [f"{displayed_path}: jobs must be a mapping"]

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
                    f"{displayed_path}: job {job_name} checkout step "
                    f"{step_number} persists credentials"
                )
    return failures


def accessibility_ui_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    prefix = f"{display_path(path, root)}: accessibility UI contract"
    job, steps, failures = workflow_job_steps(
        workflow, job_name="swift", prefix=prefix
    )
    if job is None or steps is None:
        return failures

    cache, step_failures = named_step(
        steps,
        name="Cache Swift and Xcode build artifacts",
        prefix=prefix,
    )
    failures.extend(step_failures)
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

    ui_test, step_failures = named_step(
        steps,
        name="Test focused accessibility UI contracts",
        prefix=prefix,
    )
    failures.extend(step_failures)
    if ui_test is not None:
        failures.extend(
            reviewed_run_context_failures(
                workflow,
                job,
                ui_test,
                job_name="swift",
                step_name="Test focused accessibility UI contracts",
                prefix=prefix,
            )
        )
        if ui_test.get("timeout-minutes") != 30:
            failures.append(f"{prefix} UI test timeout must be 30 minutes")
        run = ui_test.get("run")
        if not isinstance(run, str):
            failures.append(f"{prefix} UI test step must contain a shell command")
        else:
            try:
                command = _parse_single_shell_command(run)
            except ValueError as error:
                failures.append(f"{prefix} UI test shell command is malformed: {error}")
            else:
                if command.tokens[:2] != ("xcodebuild", "test"):
                    failures.append(
                        f"{prefix} UI test step must run xcodebuild test directly"
                    )
                else:
                    mismatch = exact_command_mismatch(
                        command.tokens, ACCESSIBILITY_UI_TEST_COMMAND
                    )
                    if mismatch is not None:
                        failures.append(
                            f"{prefix} UI test command argument errors: {mismatch}"
                        )
                    else:
                        quoted_values = (
                            ACCESSIBILITY_UI_TEST_COMMAND[
                                ACCESSIBILITY_UI_TEST_COMMAND.index(flag) + 1
                            ]
                            for flag in ACCESSIBILITY_UI_DOUBLE_QUOTED_FLAGS
                        )
                        unquoted_values = [
                            value
                            for value in quoted_values
                            if command.double_quoted_values.count(value) != 1
                        ]
                        if unquoted_values:
                            failures.append(
                                f"{prefix} UI test runner paths must be "
                                "double-quoted: " + ", ".join(unquoted_values)
                            )

    upload, step_failures = named_step(
        steps,
        name="Upload accessibility UI test results",
        prefix=prefix,
    )
    failures.extend(step_failures)
    if upload is not None:
        if upload.get("uses") != ACCESSIBILITY_UPLOAD_ACTION:
            failures.append(f"{prefix} upload action is not pinned to the reviewed SHA")
        condition = upload.get("if")
        normalized_condition = (
            "".join(condition.split()) if isinstance(condition, str) else None
        )
        if normalized_condition not in {"always()", "${{always()}}"}:
            failures.append(f"{prefix} result upload must run even after test failure")
        inputs = upload.get("with")
        if not isinstance(inputs, dict) or inputs.get("path") != (
            "${{ runner.temp }}/creg-accessibility-ui-tests.xcresult"
        ):
            failures.append(f"{prefix} result upload path is incorrect")

    return failures


def testflight_publisher_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    prefix = f"{display_path(path, root)}: TestFlight publisher test contract"
    job, steps, failures = workflow_job_steps(
        workflow, job_name="python", prefix=prefix
    )
    if job is None or steps is None:
        return failures
    publisher_test, step_failures = named_step(
        steps,
        name="Run TestFlight publisher tests",
        prefix=prefix,
    )
    failures.extend(step_failures)
    if publisher_test is None:
        return failures

    failures.extend(
        reviewed_run_context_failures(
            workflow,
            job,
            publisher_test,
            job_name="python",
            step_name="Run TestFlight publisher tests",
            prefix=prefix,
        )
    )

    run = publisher_test.get("run")
    if not isinstance(run, str):
        failures.append(f"{prefix} step must contain a shell command")
        return failures
    try:
        command = _parse_single_shell_command(run)
    except ValueError as error:
        failures.append(f"{prefix} shell command is malformed: {error}")
        return failures
    mismatch = exact_command_mismatch(
        command.tokens, TESTFLIGHT_PUBLISHER_TEST_COMMAND
    )
    if mismatch is not None:
        failures.append(
            f"{prefix} must use the reviewed uv-managed Python 3.13 command: "
            f"{mismatch}"
        )
        return failures
    if command.single_quoted_values.count("test_*.py") != 1:
        failures.append(f"{prefix} test discovery pattern must be single-quoted")
    return failures


def main(
    *,
    root: Path | None = None,
    workflow_directory: Path | None = None,
) -> None:
    effective_root = ROOT if root is None else root
    effective_workflows = (
        WORKFLOWS if workflow_directory is None else workflow_directory
    )
    failures: list[str] = []
    workflows = load_workflows(effective_workflows)
    for path, source, workflow in workflows:
        lines = source.splitlines()
        for number, line in enumerate(lines, start=1):
            if "uses:" in line and not PINNED_ACTION.match(line):
                failures.append(
                    f"{display_path(path, effective_root)}:{number}: "
                    "action is not SHA-pinned"
                )
        failures.extend(
            checkout_credential_failures(path, workflow, root=effective_root)
        )
    matches = accessibility_workflows(workflows)
    if len(matches) != 1:
        failures.append(
            f"{display_path(effective_workflows, effective_root)}: "
            "accessibility UI contract requires "
            f"exactly one workflow named {ACCESSIBILITY_WORKFLOW_NAME!r}"
        )
    else:
        path, workflow = matches[0]
        failures.extend(
            accessibility_ui_contract_failures(
                path, workflow, root=effective_root
            )
        )
        failures.extend(
            testflight_publisher_contract_failures(
                path, workflow, root=effective_root
            )
        )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
