"""Fail CI when workflow supply-chain safeguards regress."""

from __future__ import annotations

import re
import shlex
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
PINNED_ACTION = re.compile(r"^\s*uses:\s*[^\s]+@([0-9a-f]{40})(?:\s+#.*)?$")
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_UV_ACTION = "astral-sh/setup-uv@37802adc94f370d6bfd71619e3f0bf239e1f3b78"
SETUP_UV_ENV: Mapping[str, str] = MappingProxyType(
    {
        "BASH_ENV": "",
        "ENV": "",
        "LD_PRELOAD": "",
        "NODE_OPTIONS": "",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
)
CI_WORKFLOW_NAME = "CI"
METAL_TOOLCHAIN_STEP: Mapping[str, str] = MappingProxyType(
    {"name": "Install Metal Toolchain", "run": "xcodebuild -downloadComponent MetalToolchain"}
)
REVIEWED_RUN_WORKING_DIRECTORY = "${{ github.workspace }}"
SWIFT_DEPENDENCY_JOB_TIMEOUT = 30
UBUNTU_REVIEWED_RUN_SHELL = (
    "/usr/bin/env -i HOME=/home/runner "
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin "
    "/bin/bash --noprofile --norc -e -o pipefail {0}"
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
SECURITY_CHECKER_JOB = "security"
SECURITY_CHECKER_RUNNER = "ubuntu-latest"
SECURITY_CHECKER_UV_PATH = "${{ steps.setup-security-uv.outputs.uv-path }}"
SECURITY_CHECKER_WORKING_DIRECTORY = "${{ github.workspace }}/fine-tuning"
SECURITY_CHECKER_COMMAND = (
    "TMPDIR=${{ runner.temp }}",
    "UV_NO_CONFIG=1",
    SECURITY_CHECKER_UV_PATH,
    "run",
    "--frozen",
    "python",
    "-m",
    "tools.check_ci_contracts",
)
SEMGREP_FIXTURE_TEST_RUN = (
    "uvx --from semgrep==1.170.0 semgrep scan --metrics off --json "
    "--config .semgrep.yml semgrep-tests | uv run --no-project python "
    "fine-tuning/tools/check_semgrep_fixtures.py semgrep-tests"
)
LoadedWorkflow = tuple[Path, str, object]


@dataclass(frozen=True)
class ParsedShellCommand:
    tokens: tuple[str, ...]
    single_quoted_values: tuple[str, ...]
    double_quoted_values: tuple[str, ...]
    single_quoted_words: tuple[str, ...]
    double_quoted_words: tuple[str, ...]


def setup_uv_step(*, identifier: str) -> dict[str, object]:
    """Return a fresh reviewed setup-uv step without mutable shared state."""
    return {
        "name": "Install uv",
        "id": identifier,
        "uses": SETUP_UV_ACTION,
        "env": dict(SETUP_UV_ENV),
        "with": {
            "version": "0.12.7",
            "checksum": (
                "788f18abea7c5f55d6216e4f5613fd89"
                "d4d59b631efeec117b2b07fe72f1da21"
            ),
            "enable-cache": False,
        },
    }


def testflight_publisher_bootstrap_steps() -> tuple[dict[str, object], ...]:
    return (
        {
            "name": "Check out repository",
            "uses": CHECKOUT_ACTION,
            "with": {"persist-credentials": False},
        },
        setup_uv_step(identifier="setup-uv"),
    )


def security_checker_bootstrap_steps() -> tuple[dict[str, object], ...]:
    checkout = {
        "name": "Check out repository",
        "uses": CHECKOUT_ACTION,
        "with": {"persist-credentials": False, "fetch-depth": 2},
    }
    return (checkout, setup_uv_step(identifier="setup-security-uv"))


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
    word_quote_modes: list[frozenset[str]] = []
    current_word_quote_modes: set[str] = set()
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
            current_word_quote_modes.add("unquoted")
            at_word_start = False
            index += 2
            continue
        if character in "'\"":
            normalized_parts.append(character)
            quote = character
            quoted_parts = []
            current_word_quote_modes.add(
                "single" if character == "'" else "double"
            )
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
        if character in " \t":
            if not at_word_start:
                word_quote_modes.append(frozenset(current_word_quote_modes))
                current_word_quote_modes.clear()
        else:
            current_word_quote_modes.add("unquoted")
        normalized_parts.append(character)
        at_word_start = character in " \t\r\n"
        index += 1

    if not at_word_start:
        word_quote_modes.append(frozenset(current_word_quote_modes))
    normalized = "".join(normalized_parts).strip(" \t\r\n")
    tokens = tuple(shlex.split(normalized, comments=False, posix=True))
    if len(tokens) != len(word_quote_modes):
        raise ValueError("must use supported shell word quoting")
    return ParsedShellCommand(
        tokens=tokens,
        single_quoted_values=tuple(single_quoted_values),
        double_quoted_values=tuple(double_quoted_values),
        single_quoted_words=tuple(
            token
            for token, modes in zip(tokens, word_quote_modes, strict=True)
            if modes == {"single"}
        ),
        double_quoted_words=tuple(
            token
            for token, modes in zip(tokens, word_quote_modes, strict=True)
            if modes == {"double"}
        ),
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


def reviewed_job_context_failures(
    job: dict[object, object],
    *,
    job_name: str,
    prefix: str,
    expected_runner: str,
    expected_job_timeout: int | None = None,
    expected_strategy: Mapping[str, object] | None = None,
) -> list[str]:
    """Reject job metadata that can skip or reinterpret a reviewed run."""
    failures: list[str] = []
    job_fields = [
        field
        for field in (
            "container",
            "continue-on-error",
            "defaults",
            "env",
            "if",
            "needs",
            "permissions",
            "services",
            "strategy",
            "timeout-minutes",
        )
        if field in job and not (
            field == "timeout-minutes"
            and expected_job_timeout is not None
            and type(job[field]) is int
            and job[field] == expected_job_timeout
        ) and not (field == "strategy" and expected_strategy is not None
                   and job[field] == expected_strategy)
    ]
    if expected_strategy is not None and "strategy" not in job:
        failures.append(f"{prefix} {job_name} job must include the reviewed shard strategy")
    if expected_job_timeout is not None and "timeout-minutes" not in job:
        failures.append(f"{prefix} {job_name} job timeout-minutes must be {expected_job_timeout}")
    if job_fields:
        failures.append(
            f"{prefix} {job_name} job must not override reviewed run context: "
            + ", ".join(job_fields)
        )
    if job.get("runs-on") != expected_runner:
        failures.append(
            f"{prefix} {job_name} job must run on {expected_runner}"
        )
    return failures


def reviewed_step_context_failures(
    step: dict[object, object],
    *,
    step_name: str,
    prefix: str,
    expected_shell: str,
    expected_working_directory: str,
) -> list[str]:
    """Reject step metadata that can skip or reinterpret a reviewed run."""
    failures: list[str] = []
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
    expected_job_timeout: int | None = None,
    expected_strategy: Mapping[str, object] | None = None,
) -> list[str]:
    """Compose job and step checks for a single reviewed run."""
    return [
        *reviewed_job_context_failures(
            job, job_name=job_name, prefix=prefix, expected_runner=expected_runner,
            expected_job_timeout=expected_job_timeout, expected_strategy=expected_strategy,
        ),
        *reviewed_step_context_failures(
            step, step_name=step_name, prefix=prefix, expected_shell=expected_shell,
            expected_working_directory=expected_working_directory,
        ),
    ]


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
    expected_steps: Sequence[Mapping[str, object]],
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


def ci_workflows(
    workflows: Sequence[LoadedWorkflow] | None = None,
) -> list[tuple[Path, object]]:
    loaded = load_workflows() if workflows is None else workflows
    return [
        (path, workflow)
        for path, _, workflow in loaded
        if isinstance(workflow, dict)
        and workflow.get("name") == CI_WORKFLOW_NAME
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


def _testflight_publisher_job_contract_failures(
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
            testflight_publisher_bootstrap_steps(),
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
    if command.single_quoted_words.count("test_*.py") != 1:
        failures.append(f"{prefix} test discovery pattern must be single-quoted")
    if command.double_quoted_words.count(TESTFLIGHT_UV_PATH) != 1:
        failures.append(f"{prefix} setup-uv output path must be double-quoted")
    return failures


def testflight_publisher_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    return [
        *reviewed_workflow_context_failures(path, workflow, root=root),
        *_testflight_publisher_job_contract_failures(path, workflow, root=root),
    ]


def _security_checker_job_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    prefix = f"{display_path(path, root)}: security checker contract"
    job, steps, failures = workflow_job_steps(
        workflow, job_name=SECURITY_CHECKER_JOB, prefix=prefix
    )
    if job is None or steps is None:
        return failures
    checker, step_failures = named_step(
        steps,
        name="Verify workflow action pins",
        prefix=prefix,
    )
    failures.extend(step_failures)
    if checker is None:
        return failures

    failures.extend(
        reviewed_bootstrap_failures(
            steps,
            checker,
            security_checker_bootstrap_steps(),
            step_name="Verify workflow action pins",
            prefix=prefix,
        )
    )
    failures.extend(
        reviewed_run_context_failures(
            job,
            checker,
            job_name=SECURITY_CHECKER_JOB,
            step_name="Verify workflow action pins",
            prefix=prefix,
            expected_runner=SECURITY_CHECKER_RUNNER,
            expected_shell=UBUNTU_REVIEWED_RUN_SHELL,
            expected_working_directory=SECURITY_CHECKER_WORKING_DIRECTORY,
        )
    )
    run = checker.get("run")
    if not isinstance(run, str):
        failures.append(f"{prefix} step must contain a shell command")
        return failures
    try:
        command = _parse_single_shell_command(run)
    except ValueError as error:
        failures.append(f"{prefix} shell command is malformed: {error}")
        return failures
    mismatch = exact_command_mismatch(command.tokens, SECURITY_CHECKER_COMMAND)
    if mismatch is not None:
        failures.append(
            f"{prefix} must use the reviewed uv command: {mismatch}"
        )
        return failures
    unquoted_values = []
    if command.double_quoted_values.count("${{ runner.temp }}") != 1:
        unquoted_values.append("${{ runner.temp }}")
    if command.double_quoted_words.count(SECURITY_CHECKER_UV_PATH) != 1:
        unquoted_values.append(SECURITY_CHECKER_UV_PATH)
    if unquoted_values:
        failures.append(
            f"{prefix} runner-controlled values must be double-quoted: "
            + ", ".join(unquoted_values)
        )
    fixture_test, step_failures = named_step(
        steps,
        name="Test Semgrep rules",
        prefix=prefix,
    )
    failures.extend(step_failures)
    expected_fixture_test = {
        "name": "Test Semgrep rules",
        "shell": "bash",
        "run": SEMGREP_FIXTURE_TEST_RUN,
    }
    if fixture_test is not None and fixture_test != expected_fixture_test:
        failures.append(
            f"{prefix} Semgrep fixture test mismatch: "
            f"expected_fixture_test={expected_fixture_test!r}; "
            f"actual fixture_test={fixture_test!r}"
        )
    return failures


def security_checker_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    return [
        *reviewed_workflow_context_failures(path, workflow, root=root),
        *_security_checker_job_contract_failures(path, workflow, root=root),
    ]


def metal_toolchain_job_failures(
    path: Path,
    workflow: object,
    *,
    job_name: str,
    build_step_name: str,
    root: Path | None = None,
) -> list[str]:
    prefix = f"{display_path(path, root)}: {job_name} Metal Toolchain contract"
    job, steps, failures = workflow_job_steps(
        workflow, job_name=job_name, prefix=prefix
    )
    if job is None or steps is None:
        return failures
    if job.get("runs-on") != "xcode-27":
        failures.append(f"{prefix} must use the xcode-27 runner")
    expected = dict(METAL_TOOLCHAIN_STEP)
    if len(steps) < 2 or steps[1] != expected:
        failures.append(f"{prefix} must install Metal immediately after checkout")
    if sum(step.get("name") == expected["name"] for step in steps) != 1:
        failures.append(f"{prefix} must have exactly one Metal install step")
    build, build_failures = named_step(
        steps, name=build_step_name, prefix=prefix
    )
    failures.extend(build_failures)
    if build is not None and steps.index(build) <= 1:
        failures.append(f"{prefix} must install Metal before compiling")
    return failures


def _shell_command_string(arguments: list[str]) -> str | None:
    """Find a shell's -c operand after processing invocation options."""
    command_mode = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if argument in {"--help", "--version"}:
            return None
        if argument in {"--rcfile", "--init-file"}:
            index += 2
            continue
        if argument.startswith("--"):
            index += 1
            continue
        if len(argument) > 1 and argument[0] in "-+":
            flags = argument[1:]
            if argument[0] == "-" and "c" in flags:
                command_mode = True
            # -o/-O take a separate option name even when clustered with -c.
            index += 2 if any(flag in flags for flag in "oO") else 1
            continue
        break
    return arguments[index] if command_mode and index < len(arguments) else None


def _short_option_flags(argument: str, values: str) -> str:
    if argument.startswith("--"):
        return ""
    for offset, flag in enumerate(argument[1:], start=1):
        if flag in values:
            return argument[1:offset + 1]
    return argument[1:]


def _option_end(arguments: list[str], index: int, values: set[str],
                short_values: str = "") -> int:
    """Skip one option, including its operand or an attached operand."""
    argument = arguments[index]
    if argument in values:
        return index + 2
    if "=" in argument or argument.startswith("--"):
        return index + 1
    for offset, flag in enumerate(argument[1:], start=1):
        if flag in short_values:
            return index + (2 if offset == len(argument) - 1 else 1)
    return index + 1


def _policy_arguments(arguments: list[str], values: set[str], *,
                      short_values: str = "", arrays: frozenset[str] | set[str] = frozenset(),
                      cli_help: bool = False
                      ) -> tuple[list[str], set[str]]:
    """Separate command operands from options, never interpreting option values."""
    operands: list[str] = []
    options: set[str] = set()
    help_flags = {"-h", "--help", "-v", "--version"}

    def is_help_option(argument: str) -> bool:
        return (argument.split("=", 1)[0] in help_flags
                or not argument.startswith("--") and argument.startswith(("-h", "-v")))

    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            operands.extend(arguments[index + 1:])
            break
        if not argument.startswith("-") or argument == "-":
            operands.append(argument)
            index += 1
            continue
        option = argument.split("=", 1)[0]
        if cli_help and option in help_flags:
            # yargs help/version booleans can explicitly be disabled.
            if "=" in argument:
                if argument.split("=", 1)[1] == "true":
                    options.add(option)
                index += 1
            elif index + 1 < len(arguments) and arguments[index + 1] in {"true", "false"}:
                if arguments[index + 1] == "true":
                    options.add(option)
                index += 2
            else:
                options.add(option)
                index += 1
            continue
        if cli_help and is_help_option(argument):
            options.add(argument[:2])
            index += 1
            continue
        options.add(option)
        if option in arrays:
            index += 1
            while (index < len(arguments)
                   and arguments[index].split("=", 1)[0] not in values
                   and not (cli_help and is_help_option(arguments[index]))):
                index += 1
        elif (cli_help and argument in values and index + 1 < len(arguments)
              and is_help_option(arguments[index + 1])):
            # A separate known boolean flag is not a yargs string operand.
            index += 1
        else:
            index = _option_end(arguments, index, values, short_values)
    return operands, options


POLICY_WRAPPERS = {"env", "command", "exec", "nohup", "sudo", "time", "nice",
                   "timeout", "gtimeout", "stdbuf", "gstdbuf", "xcrun"}
WRAPPER_VALUE_OPTIONS = {
    "env": ({"-u", "--unset", "-C", "--chdir", "-P", "-S", "--split-string", "--argv0"}, "uCPS"),
    "command": (set(), ""),
    "exec": ({"-a"}, "a"),
    "nohup": (set(), ""),
    "sudo": ({"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
              "-D", "--chdir", "-R", "--chroot", "-T", "--command-timeout", "-C",
              "--close-from", "-U", "--other-user", "-r", "--role", "-t", "--type"}, "ughpDRTCUrt"),
    "time": ({"-f", "--format", "-o", "--output"}, "fo"),
    "nice": ({"-n", "--adjustment"}, "n"),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, "sk"),
    "stdbuf": ({"-i", "--input", "-o", "--output", "-e", "--error"}, "ioe"),
    "xcrun": ({"-sdk", "--sdk", "-toolchain", "--toolchain"}, ""),
}


def _wrapper_command(executable: str, arguments: list[str]) -> list[str] | None:
    executable = {"gtimeout": "timeout", "gstdbuf": "stdbuf"}.get(executable, executable)
    values, short_values = WRAPPER_VALUE_OPTIONS[executable]
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--":
            index += 1
            break
        if executable == "env" and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", argument):
            index += 1
            continue
        if not argument.startswith("-") or argument == "-":
            break
        option = argument.split("=", 1)[0]
        if option in {"--help", "--version"}:
            return None
        if executable == "xcrun":
            if option in {"-find", "--find", "-help", "-version"} or option.startswith(("--show-", "-show-")):
                return None
            # Single-dash long aliases are not clusters of short options.
            if option not in values | {"-no-cache", "-kill-cache", "-verbose", "-log", "-run"}:
                flags = argument[1:]
                if flags and set(flags) <= set("hvlfrnk") and set(flags) & {"h", "f"}:
                    return None
        elif executable == "command" and set(_short_option_flags(argument, "")) & {"v", "V"}:
            return None
        elif executable == "sudo":
            if option in {"--list", "--validate", "--edit", "--remove-timestamp"} or set(_short_option_flags(argument, short_values)) & {"l", "v", "V", "e", "K"}:
                return None
        if executable == "env" and (option == "--split-string" or "S" in _short_option_flags(argument, short_values)):
            if argument.startswith("--") and "=" in argument:
                script = argument.split("=", 1)[1]
                following = index + 1
            elif option == "--split-string" or argument.endswith("S"):
                if index + 1 >= len(arguments):
                    return None
                script = arguments[index + 1]
                following = index + 2
            else:
                script = argument[argument.index("S") + 1:]
                following = index + 1
            return shlex.split(script) + arguments[following:]
        index = _option_end(arguments, index, values, short_values)
    if executable == "timeout":
        index += 1  # Duration precedes the command.
    return arguments[index:]


def _policy_command_head(tokens: list[str]) -> list[str]:
    while tokens and (
        re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", tokens[0])
        or tokens[0] in {"if", "then", "elif", "else", "while", "until", "do", "!", "{"}
    ):
        tokens = tokens[1:]
    while tokens and tokens[0].rsplit("/", 1)[-1] in POLICY_WRAPPERS:
        tokens = _wrapper_command(tokens[0].rsplit("/", 1)[-1], tokens[1:]) or []
        while tokens and (
            re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", tokens[0])
            or tokens[0] in {"if", "then", "elif", "else", "while", "until", "do", "!", "{"}
        ):
            tokens = tokens[1:]
    return tokens


SWIFT_VALUE_OPTIONS = {
    "--package-path", "--cache-path", "--config-path", "--security-path", "--scratch-path",
    "--swift-sdks-path", "--toolset", "--pkg-config-path", "--manifest-cache", "--netrc-file",
    "--resolver-fingerprint-checking", "--resolver-signing-entity-checking", "--default-registry-url",
    "-c", "--configuration", "-Xcc", "-Xswiftc", "-Xlinker", "-Xcxx", "--triple", "--sdk",
    "--toolchain", "--swift-sdk", "--sanitize", "-j", "--jobs", "--traits", "--arch",
    "--explicit-target-dependency-import-check", "--build-system", "-debug-info-format",
    "--experimental-codesize-profile-output-dir", "--attachments-path", "--filter", "--skip",
    "--num-workers", "--test-product", "--xunit-output", "--destination",
}
XCODEBUILD_VALUE_OPTIONS = {
    "-project", "-workspace", "-scheme", "-target", "-configuration", "-sdk", "-toolchain",
    "-arch", "-destination", "-destination-timeout", "-jobs", "-derivedDataPath",
    "-resultBundlePath", "-resultBundleVersion", "-resultStreamPath", "-archivePath",
    "-xcconfig", "-xctestrun", "-testPlan", "-testProductsPath", "-clonedSourcePackagesDirPath",
    "-packageCachePath", "-parallel-testing-worker-count", "-maximum-concurrent-test-simulator-destinations",
    "-maximum-concurrent-test-device-destinations", "-test-timeouts-enabled", "-test-iterations",
    "-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance",
    "-parallel-testing-enabled", "-enableCodeCoverage", "-only-testing", "-skip-testing",
    "-downloadPlatform", "-importPlatform", "-downloadComponent", "-exportPath", "-buildVersion",
    "-architectureVariant", "-exportOptionsPlist", "-localizationPath", "-exportLanguage", "-authenticationKeyPath",
    "-authenticationKeyID", "-authenticationKeyIssuerID",
}
XCODEBUILDMCP_VALUE_OPTIONS = {
    "--log-level", "--style", "--file-path-render-style", "--socket", "--profile", "--json",
    "--output", "--project-path", "--workspace-path", "--scheme", "--simulator-id",
    "--simulator-name", "--configuration", "--derived-data-path", "--package-path", "--filter",
    "--test-product", "--bundle-id", "--device-id", "--extra-args", "--launch-args",
}


def _invocation_executes_apple_tests(tokens: list[str]) -> bool:
    """Inspect known executables and wrappers, without running shell source."""
    tokens = _policy_command_head(tokens)
    if not tokens:
        return False
    executable = tokens[0].rsplit("/", 1)[-1]
    arguments = tokens[1:]
    if executable in {"bash", "sh", "zsh"}:
        script = _shell_command_string(arguments)
        return script is not None and _executes_apple_tests(script)
    if executable == "simctl":
        operands, options = _policy_arguments(arguments, {"--set", "--profiles"})
        if options & {"-h", "--help"} or not operands:
            return False
        return (operands[0] in {"create", "clone", "boot", "reboot"}
                or operands[0] == "bootstatus" and "-b" in options
                or operands[:2] in [["runtime", "add"], ["runtime", "scan-and-mount"]])
    if executable == "swift":
        operands, options = _policy_arguments(arguments, SWIFT_VALUE_OPTIONS, short_values="cj")
        return not options & {"-h", "--help", "--version"} and operands[:1] == ["test"]
    if executable == "xcodebuild":
        operands, options = _policy_arguments(arguments, XCODEBUILD_VALUE_OPTIONS)
        # Xcode's -version takes precedence even when supplied as an option value.
        if "-version" in arguments or "-help" in options:
            return False
        return (bool(options & {"-downloadPlatform", "-downloadAllPlatforms", "-importPlatform"})
                or any(a in {"test", "test-without-building", "build-for-testing"} for a in operands))
    if executable == "xcodebuildmcp":
        operands, options = _policy_arguments(arguments, XCODEBUILDMCP_VALUE_OPTIONS,
                                             arrays={"--extra-args", "--launch-args"}, cli_help=True)
        if options & {"-h", "--help", "-v", "--version"}:
            return False
        command = operands[:2]
        return len(command) == 2 and (
            command[0] in {"swift-package", "simulator", "device", "macos"} and command[1] == "test"
            or command[0] in {"simulator", "simulator-management"} and command[1] == "boot"
            or command == ["simulator", "build-and-run"]
        )
    return False


def _shell_reads_stdin(tokens: list[str]) -> bool:
    tokens = _policy_command_head(tokens)
    if not tokens or tokens[0].rsplit("/", 1)[-1] not in {"bash", "sh", "zsh"}:
        return False
    arguments = tokens[1:]
    index = 0
    stdin_mode = False
    while index < len(arguments):
        argument = arguments[index]
        if argument in {"--help", "--version"}:
            return False
        if argument == "--":
            index += 1
            break
        if argument in {"--rcfile", "--init-file"}:
            index += 2
            continue
        if not argument.startswith(("-", "+")) or argument == "-":
            break
        if not argument.startswith("--"):
            if argument.startswith("-") and "c" in argument[1:]:
                return False
            stdin_mode |= "s" in argument[1:]
            index += 2 if set(argument[1:]) & {"o", "O"} else 1
        else:
            index += 1
    return stdin_mode or index == len(arguments) or arguments[index:] == ["-"]


def _heredoc_delimiter(source: str, index: int) -> tuple[str, bool, int]:
    start = index
    quote: str | None = None
    quoted = False
    while index < len(source):
        character = source[index]
        if character == "\\" and quote != "'":
            quoted = True
            index += 2
            continue
        if quote is not None:
            if character == quote:
                quote = None
        elif character in "'\"":
            quote = character
            quoted = True
        elif character in " \t\r\n;&|<>()":
            break
        index += 1
    words = shlex.split(source[start:index])
    if len(words) != 1:
        raise ValueError("missing heredoc delimiter")
    return words[0], quoted, index


def _ansi_c_quoted_string(source: str, index: int) -> tuple[str, int]:
    """Decode a literal $'...' word without evaluating shell expansions."""
    index += 2
    parts: list[str] = []
    escapes = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
               "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
               "'": "'", '"': '"', "?": "?"}
    while index < len(source):
        character = source[index]
        index += 1
        if character == "'":
            # Bash strings end at the first decoded NUL, but the remainder of
            # the quoted source must still be consumed as literal data.
            return "".join(parts).split("\0", 1)[0], index
        if character != "\\":
            parts.append(character)
            continue
        if index == len(source):
            break
        escaped = source[index]
        index += 1
        if escaped in escapes:
            parts.append(escapes[escaped])
        elif escaped in "01234567":
            digits = re.match(r"[0-7]{0,2}", source[index:])[0]
            parts.append(chr(int(escaped + digits, 8) & 0xff))
            index += len(digits)
        elif escaped in "xuU":
            limit = {"x": 2, "u": 4, "U": 8}[escaped]
            digits = re.match(rf"[0-9a-fA-F]{{0,{limit}}}", source[index:])[0]
            parts.append(chr(int(digits, 16)) if digits else "\\" + escaped)
            index += len(digits)
        elif escaped == "c" and index < len(source) and source[index] != "'":
            control = source[index]
            parts.append(chr(ord(control) & 0x1f))
            index += 1
            if control == "\\" and index < len(source) and source[index] == "\\":
                index += 1
        else:
            parts.append("\\" + escaped)
    raise ValueError("unterminated ANSI-C shell quote")


@dataclass
class _PolicyCase:
    phase: str = "word"
    pattern_started: bool = False
    pattern_depth: int = 0


@dataclass
class _PolicyHeredoc:
    delimiter: str
    quoted: bool
    tabs: bool
    pipeline: list[list[str]]
    owner_index: int


def _scan_policy_shell(source: str, index: int = 0, *, closing: str | None = None,
                       data: bool = False) -> tuple[list[list[str]], int]:
    """Inspect commands/expansions while retaining shell quote and heredoc context."""
    commands: list[list[str]] = []
    parts: list[str] = []
    quote: str | None = None
    word_start = True
    word_index: int | None = None
    command_start = True
    time_option = False
    arithmetic_depth = 0
    cases: list[_PolicyCase] = []
    pipeline: list[list[str]] = []
    pipeline_continues = False
    pending: list[_PolicyHeredoc] = []
    heredoc_bodies: list[tuple[_PolicyHeredoc, str]] = []

    def finish_word() -> None:
        nonlocal word_index, command_start, time_option
        if word_index is None:
            return
        # Reserved words must be unquoted and occur in a grammar position,
        # rather than merely appearing as an argument or a decoded literal.
        word = source[word_index:index].replace("\\\n", "")
        word_index = None
        if not word:
            return
        if cases and cases[-1].phase == "word":
            cases[-1].phase = "in"
        elif cases and cases[-1].phase == "in":
            if word != "in":
                raise ValueError("missing case 'in' keyword")
            cases[-1].phase = "pattern"
            parts.clear()
        elif cases and cases[-1].phase == "pattern":
            if word == "esac" and not cases[-1].pattern_started:
                cases.pop()
                parts.clear()
                command_start = False
            else:
                cases[-1].pattern_started = True
        elif command_start and word == "case":
            cases.append(_PolicyCase())
            command_start = False
            time_option = False
        elif command_start and word == "esac" and cases:
            cases.pop()
            parts.clear()
            command_start = False
        elif command_start and word == "time":
            time_option = True
        elif command_start and time_option and word == "-p":
            time_option = False
        elif command_start and (
            word in {"if", "then", "elif", "else", "while", "until", "do", "!", "{"}
            or re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", word)
        ):
            time_option = False
        else:
            command_start = False
            time_option = False

    def flush(separator: str | None = None) -> None:
        nonlocal pipeline, pipeline_continues, command_start, time_option
        tokens = shlex.split("".join(parts), posix=True)
        commands.append(tokens)
        if tokens or not pipeline_continues:
            pipeline.append(tokens)
        parts.clear()
        if separator in {"|", "|&"}:
            pipeline_continues = True
        elif not (separator == "\n" and not tokens and pipeline_continues):
            pipeline = []
            pipeline_continues = False
        command_start = True
        time_option = False

    def scan_heredoc_bodies() -> None:
        for doc, body in heredoc_bodies:
            # Unquoted bodies expand in the outer shell even when their text
            # also becomes a script for a downstream shell.
            if not doc.quoted:
                commands.extend(_scan_policy_shell(body, data=True)[0])
            if any(_shell_reads_stdin(command) for command in doc.pipeline[doc.owner_index:]):
                commands.extend(_shell_commands(body))

    while index < len(source):
        character = source[index]
        if not data and quote is None:
            if character in " \t\r\n;&|()<>":
                finish_word()
            elif word_index is None:
                word_index = index
        case_pattern = bool(cases and cases[-1].phase == "pattern")
        if (quote is None and closing and source.startswith(closing, index)
                and arithmetic_depth == 0 and not (closing == ")" and cases)):
            if cases:
                raise ValueError("unterminated shell case")
            if not data:
                flush()
            if pending:
                raise ValueError("unterminated heredoc")
            scan_heredoc_bodies()
            return commands, index + len(closing)
        if closing == "`" and source.startswith("\\`", index) and quote != "'":
            nested, index = _scan_policy_shell(source, index + 2, closing="\\`")
            commands.extend(nested)
            if not data:
                parts.append("_CREG_SUBSTITUTION_")
            continue
        if character == "\\" and quote != "'":
            if not data and source[index:index + 2] != "\\\n":
                parts.append(source[index:index + 2])
            index += 2
            word_start = False
            continue
        if quote is None and not data and source.startswith("$'", index):
            literal, index = _ansi_c_quoted_string(source, index)
            # shlex does not implement ANSI-C quoting; give it an ordinary
            # safely quoted word while preserving adjacent word fragments.
            parts.append(shlex.quote(literal))
            word_start = False
            continue
        expansion_start = index + 1
        if character == "$":
            while source.startswith("\\\n", expansion_start):
                expansion_start += 2
        substitution = character == "$" and source.startswith("(", expansion_start)
        if quote != "'" and (substitution or character == "`"):
            arithmetic = substitution and source.startswith("((", expansion_start)
            backtick = character == "`"
            nested, index = _scan_policy_shell(
                source, index + 1 if backtick else expansion_start + (2 if arithmetic else 1),
                closing="`" if backtick else "))" if arithmetic else ")", data=arithmetic)
            commands.extend(nested)
            if not data:
                parts.append("_CREG_SUBSTITUTION_")
            word_start = False
            continue
        if data:
            if closing == "))":
                if character == "(":
                    arithmetic_depth += 1
                elif character == ")" and arithmetic_depth:
                    arithmetic_depth -= 1
            index += 1
            continue
        if quote is not None:
            parts.append(character)
            if character == quote:
                quote = None
        elif character in "'\"":
            quote = character
            parts.append(character)
        elif character == "#" and word_start:
            word_index = None
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline
            continue
        elif source.startswith("<<", index) and not source.startswith("<<<", index):
            tabs = source.startswith("<<-", index)
            index += 3 if tabs else 2
            while index < len(source) and source[index] in " \t":
                index += 1
            delimiter, quoted, index = _heredoc_delimiter(source, index)
            pending.append(_PolicyHeredoc(delimiter, quoted, tabs, pipeline, len(pipeline)))
            parts.append(" ")
            word_start = True
            continue
        elif case_pattern and character == "(":
            if cases[-1].pattern_started:
                cases[-1].pattern_depth += 1
            cases[-1].pattern_started = True
            parts.append(character)
        elif case_pattern and character == ")":
            if cases[-1].pattern_depth:
                cases[-1].pattern_depth -= 1
                parts.append(character)
            else:
                cases[-1].phase = "body"
                parts.clear()
                command_start = True
            word_start = True
            index += 1
            continue
        elif case_pattern and character == "|":
            parts.append(character)
            word_start = True
            index += 1
            continue
        elif character == "(" or source.startswith(("<(", ">("), index):
            flush()
            nested, index = _scan_policy_shell(source, index + (1 if character == "(" else 2), closing=")")
            commands.extend(nested)
            word_start = True
            continue
        elif character == ")":
            raise ValueError("unmatched shell parenthesis")
        elif character in ";&|\n":
            separator = next((operator for operator in (";;&", ";;", ";&", "&&", "||", "|&")
                              if source.startswith(operator, index)), character)
            if separator in {";;", ";&", ";;&"}:
                if not cases or cases[-1].phase != "body":
                    raise ValueError("unexpected shell case terminator")
                flush(separator)
                cases[-1] = _PolicyCase(phase="pattern")
            elif case_pattern:
                if separator != "\n":
                    raise ValueError("unexpected operator in case pattern")
                parts.clear()
            else:
                flush(separator)
            word_start = True
            index += len(separator)
            if character == "\n":
                for doc in pending:
                    body: list[str] = []
                    while True:
                        if index >= len(source):
                            raise ValueError("unterminated heredoc")
                        newline = source.find("\n", index)
                        end = len(source) if newline < 0 else newline + 1
                        line = source[index:end]
                        index = end
                        if doc.tabs:
                            line = line.lstrip("\t")
                        if line.removesuffix("\n") == doc.delimiter:
                            break
                        body.append(line)
                    # A pipeline may continue after this physical newline and
                    # heredoc. Inspect the body once all consumers are known.
                    heredoc_bodies.append((doc, "".join(body)))
                pending.clear()
            continue
        else:
            parts.append(character)
        word_start = quote is None and character in " \t\r"
        index += 1
    finish_word()
    if closing:
        raise ValueError("unterminated shell substitution or group")
    if pending:
        raise ValueError("unterminated heredoc")
    if cases:
        raise ValueError("unterminated shell case")
    if not data:
        flush()
    scan_heredoc_bodies()
    return commands, index


def _shell_commands(source: str) -> list[list[str]]:
    return _scan_policy_shell(source)[0]


def _executes_apple_tests(source: str) -> bool:
    return any(_invocation_executes_apple_tests(command) for command in _shell_commands(source))


def local_apple_test_policy_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    """Keep Apple tests and simulator provisioning local in every workflow."""
    if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs"), dict):
        return []
    prefix = f"{display_path(path, root)}: local Apple testing policy"
    failures = []
    for job_name, job in workflow["jobs"].items():
        if job_name in {"accessibility", "accessibility-contracts"}:
            failures.append(f"{prefix} forbids removed job {job_name}")
        if not isinstance(job, dict):
            continue
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            try:
                apple_test = _executes_apple_tests(step["run"])
            except ValueError:
                # A malformed shell step cannot establish compliance.
                failures.append(f"{prefix} job {job_name} has malformed shell syntax")
                continue
            if apple_test:
                failures.append(f"{prefix} job {job_name} executes Apple tests or provisions simulators; use local XcodeBuildMCP")
    return failures


def swift_dependency_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    prefix = f"{display_path(path, root)}: Swift dependency contract"
    job, steps, failures = workflow_job_steps(workflow, job_name="swift", prefix=prefix)
    if job is None or steps is None:
        return failures
    if job.get("name") != "Swift dependency checks":
        failures.append(f"{prefix} must retain the Swift dependency checks job name")
    failures.extend(reviewed_job_context_failures(
        job, job_name="swift", prefix=prefix, expected_runner="xcode-27",
        expected_job_timeout=SWIFT_DEPENDENCY_JOB_TIMEOUT,
    ))
    expected_commands = {
        "Verify AutoTableCharts pin agreement": "python3 fine-tuning/tools/check_swift_package_pins.py",
        "Verify checked-in Swift package resolutions": (
            "swift package --package-path CREGKit resolve "
            "xcodebuild -resolvePackageDependencies -project CREG.xcodeproj -scheme CREG "
            '-clonedSourcePackagesDirPath "${RUNNER_TEMP}/creg-source-packages" '
            "git diff --exit-code -- CREGKit/Package.resolved "
            "CREG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ),
    }
    for name, expected in expected_commands.items():
        step, step_failures = named_step(steps, name=name, prefix=prefix)
        failures.extend(step_failures)
        if step is not None:
            failures.extend(reviewed_step_context_failures(
                step, step_name=name, prefix=prefix, expected_shell="bash",
                expected_working_directory=REVIEWED_RUN_WORKING_DIRECTORY,
            ))
            command = step.get("run", "")
            normalized = " ".join(command.replace("\\\n", "").split()) if isinstance(command, str) else None
            if normalized != expected:
                failures.append(f"{prefix} {name} command changed")
    return failures


def reviewed_ci_contract_failures(
    path: Path, workflow: object, *, root: Path | None = None
) -> list[str]:
    """Compose all reviewed workflow contracts without duplicate context errors."""
    return [
        *reviewed_workflow_context_failures(path, workflow, root=root),
        *swift_dependency_contract_failures(path, workflow, root=root),
        *_testflight_publisher_job_contract_failures(path, workflow, root=root),
        *_security_checker_job_contract_failures(path, workflow, root=root),
    ]


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
        failures.extend(local_apple_test_policy_failures(path, workflow, root=effective_root))
        if isinstance(workflow, dict) and workflow.get("name") == "Documentation":
            failures.extend(metal_toolchain_job_failures(
                path, workflow, job_name="build",
                build_step_name="Generate static documentation", root=effective_root,
            ))
    matches = ci_workflows(workflows)
    if len(matches) != 1:
        failures.append(
            f"{display_path(effective_workflows, effective_root)}: "
            "CI contract requires "
            f"exactly one workflow named {CI_WORKFLOW_NAME!r}"
        )
    else:
        path, workflow = matches[0]
        failures.extend(
            reviewed_ci_contract_failures(
                path, workflow, root=effective_root
            )
        )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    main()
