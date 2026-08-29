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
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
ACCESSIBILITY_UPLOAD_ACTION = (
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
)
SETUP_UV_ACTION = "astral-sh/setup-uv@37802adc94f370d6bfd71619e3f0bf239e1f3b78"
SETUP_UV_ENV = {
    "BASH_ENV": "",
    "ENV": "",
    "LD_PRELOAD": "",
    "NODE_OPTIONS": "",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
}
ACCESSIBILITY_WORKFLOW_NAME = "CI"
ACCESSIBILITY_UI_JOB = "accessibility"
ACCESSIBILITY_UI_RUNNER = "macos-26"
REVIEWED_RUN_WORKING_DIRECTORY = "${{ github.workspace }}"
ACCESSIBILITY_UI_SHELL = (
    "/usr/bin/env -i HOME=/Users/runner "
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin "
    "/bin/bash --noprofile --norc -e -o pipefail {0}"
)
UBUNTU_REVIEWED_RUN_SHELL = (
    "/usr/bin/env -i HOME=/home/runner "
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin "
    "/bin/bash --noprofile --norc -e -o pipefail {0}"
)
ACCESSIBILITY_UI_DOUBLE_QUOTED_ARGUMENTS = (
    (
        "-clonedSourcePackagesDirPath",
        "${{ runner.temp }}/creg-source-packages",
    ),
    ("-derivedDataPath", "${{ runner.temp }}/creg-derived-data"),
    (
        "-resultBundlePath",
        "${{ runner.temp }}/creg-accessibility-ui-tests.xcresult",
    ),
)
ACCESSIBILITY_UI_TEST_COMMAND = (
    "/usr/bin/xcodebuild",
    "test",
    "-project",
    "CREG.xcodeproj",
    "-scheme",
    "CREG",
    "-destination",
    "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
    *(
        token
        for argument in ACCESSIBILITY_UI_DOUBLE_QUOTED_ARGUMENTS
        for token in argument
    ),
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
TESTFLIGHT_PUBLISHER_JOB = "testflight-publisher"
TESTFLIGHT_PUBLISHER_RUNNER = "ubuntu-latest"
TESTFLIGHT_UV_PATH = "${{ steps.setup-uv.outputs.uv-path }}"
TESTFLIGHT_PUBLISHER_TEST_COMMAND = (
    "TMPDIR=${{ runner.temp }}",
    "UV_NO_CONFIG=1",
    TESTFLIGHT_UV_PATH,
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
ACCESSIBILITY_UI_BOOTSTRAP_STEPS = (
    {
        "name": "Check out repository",
        "uses": CHECKOUT_ACTION,
        "with": {"persist-credentials": False},
    },
    {
        "name": "Select Xcode 26.3",
        "run": "sudo xcode-select --switch /Applications/Xcode_26.3.app",
    },
)
TESTFLIGHT_PUBLISHER_BOOTSTRAP_STEPS = (
    {
        "name": "Check out repository",
        "uses": CHECKOUT_ACTION,
        "with": {"persist-credentials": False},
    },
    {
        "name": "Install uv",
        "id": "setup-uv",
        "uses": SETUP_UV_ACTION,
        "env": SETUP_UV_ENV,
        "with": {
            "version": "0.12.7",
            "checksum": (
                "788f18abea7c5f55d6216e4f5613fd89"
                "d4d59b631efeec117b2b07fe72f1da21"
            ),
            "enable-cache": False,
        },
    },
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
    job: dict[object, object],
    step: dict[object, object],
    *,
    job_name: str,
    step_name: str,
    prefix: str,
    expected_runner: str,
    expected_shell: str,
    expected_working_directory: str,
) -> list[str]:
    """Reject job and step metadata that can skip or reinterpret a reviewed run."""
    failures: list[str] = []
    job_fields = [
        field
        for field in (
            "continue-on-error",
            "defaults",
            "env",
            "if",
            "needs",
            "strategy",
            "timeout-minutes",
        )
        if field in job
    ]
    if job_fields:
        failures.append(
            f"{prefix} {job_name} job must not override reviewed run context: "
            + ", ".join(job_fields)
        )
    if job.get("runs-on") != expected_runner:
        failures.append(
            f"{prefix} {job_name} job must run on {expected_runner}"
        )
    step_fields = [
        field
        for field in (
            "continue-on-error",
            "env",
            "if",
        )
        if field in step
    ]
    if step_fields:
        failures.append(
            f"{prefix} {step_name!r} step must not override reviewed run context: "
            + ", ".join(step_fields)
        )
    if step.get("shell") != expected_shell:
        failures.append(
            f"{prefix} {step_name!r} step shell must be {expected_shell!r}"
        )
    if step.get("working-directory") != expected_working_directory:
        failures.append(
            f"{prefix} {step_name!r} step working-directory must be "
            f"{expected_working_directory!r}"
        )
    return failures


def reviewed_workflow_context_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    """Reject fail-closed workflow defaults shared by reviewed run contracts."""
    prefix = f"{display_path(path, root)}: reviewed run contracts"
    if not isinstance(workflow, dict):
        return [f"{prefix} requires a workflow mapping"]
    workflow_fields = [
        field for field in ("defaults", "env") if field in workflow
    ]
    if not workflow_fields:
        return []
    return [
        f"{prefix} workflow must not override reviewed run context: "
        + ", ".join(workflow_fields)
    ]


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


def reviewed_bootstrap_failures(
    steps: Sequence[object],
    reviewed_step: dict[object, object],
    expected_steps: Sequence[dict[str, object]],
    *,
    step_name: str,
    prefix: str,
) -> list[str]:
    """Require a fresh-runner bootstrap before a reviewed executable step."""
    reviewed_index = next(
        index for index, candidate in enumerate(steps) if candidate is reviewed_step
    )
    actual_steps = steps[:reviewed_index]
    for index, (actual, expected) in enumerate(
        zip(actual_steps, expected_steps, strict=False), start=1
    ):
        if actual != expected:
            return [
                f"{prefix} {step_name!r} step has an unreviewed bootstrap "
                f"step {index}: expected {expected!r}, found {actual!r}"
            ]
    if len(actual_steps) < len(expected_steps):
        return [
            f"{prefix} {step_name!r} step is missing reviewed bootstrap "
            f"step {len(actual_steps) + 1}: {expected_steps[len(actual_steps)]!r}"
        ]
    if len(actual_steps) > len(expected_steps):
        return [
            f"{prefix} {step_name!r} step has an unexpected predecessor "
            f"at position {len(expected_steps) + 1}: "
            f"{actual_steps[len(expected_steps)]!r}"
        ]
    return []


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
        workflow, job_name=ACCESSIBILITY_UI_JOB, prefix=prefix
    )
    if job is None or steps is None:
        return failures

    ui_test, step_failures = named_step(
        steps,
        name="Test focused accessibility UI contracts",
        prefix=prefix,
    )
    failures.extend(step_failures)
    if ui_test is not None:
        failures.extend(
            reviewed_bootstrap_failures(
                steps,
                ui_test,
                ACCESSIBILITY_UI_BOOTSTRAP_STEPS,
                step_name="Test focused accessibility UI contracts",
                prefix=prefix,
            )
        )
        failures.extend(
            reviewed_run_context_failures(
                job,
                ui_test,
                job_name=ACCESSIBILITY_UI_JOB,
                step_name="Test focused accessibility UI contracts",
                prefix=prefix,
                expected_runner=ACCESSIBILITY_UI_RUNNER,
                expected_shell=ACCESSIBILITY_UI_SHELL,
                expected_working_directory=REVIEWED_RUN_WORKING_DIRECTORY,
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
                if command.tokens[:2] != ("/usr/bin/xcodebuild", "test"):
                    failures.append(
                        f"{prefix} UI test step must run xcodebuild test directly"
                    )
                else:
                    unquoted_values = [
                        value
                        for flag, value in ACCESSIBILITY_UI_DOUBLE_QUOTED_ARGUMENTS
                        if flag in command.tokens
                        and run.count(f'"{value}"') != 1
                    ]
                    if unquoted_values:
                        failures.append(
                            f"{prefix} UI test runner paths must be "
                            "double-quoted: " + ", ".join(unquoted_values)
                        )
                    else:
                        mismatch = exact_command_mismatch(
                            command.tokens, ACCESSIBILITY_UI_TEST_COMMAND
                        )
                        if mismatch is not None:
                            failures.append(
                                f"{prefix} UI test command argument errors: "
                                f"{mismatch}"
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
        workflow, job_name=TESTFLIGHT_PUBLISHER_JOB, prefix=prefix
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
        reviewed_bootstrap_failures(
            steps,
            publisher_test,
            TESTFLIGHT_PUBLISHER_BOOTSTRAP_STEPS,
            step_name="Run TestFlight publisher tests",
            prefix=prefix,
        )
    )
    failures.extend(
        reviewed_run_context_failures(
            job,
            publisher_test,
            job_name=TESTFLIGHT_PUBLISHER_JOB,
            step_name="Run TestFlight publisher tests",
            prefix=prefix,
            expected_runner=TESTFLIGHT_PUBLISHER_RUNNER,
            expected_shell=UBUNTU_REVIEWED_RUN_SHELL,
            expected_working_directory=REVIEWED_RUN_WORKING_DIRECTORY,
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
    if command.double_quoted_values.count(TESTFLIGHT_UV_PATH) != 1:
        failures.append(f"{prefix} setup-uv output path must be double-quoted")
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
            reviewed_workflow_context_failures(
                path, workflow, root=effective_root
            )
        )
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
