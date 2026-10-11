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


def _invocation_executes_apple_tests(tokens: list[str]) -> bool:
    """Inspect known executables and wrappers, without running shell source."""
    while tokens and (
        re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", tokens[0])
        or tokens[0] in {"if", "then", "elif", "else", "while", "until", "do", "!", "{"}
    ):
        tokens = tokens[1:]
    if not tokens:
        return False
    executable = tokens[0].rsplit("/", 1)[-1]
    arguments = tokens[1:]
    if executable in {"bash", "sh", "zsh"}:
        script = _shell_command_string(arguments)
        return script is not None and _executes_apple_tests(script)
    if executable in {"env", "command", "exec", "nohup", "sudo"}:
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if (
                argument in {"--help", "--version"}
                or executable == "command" and argument.startswith("-")
                and any(flag in argument[1:] for flag in "vV")
            ):
                return False
            if argument in {"-u", "--unset", "-C", "--chdir", "--user", "-g", "--group", "-a"}:
                index += 2
            elif argument.startswith("-") or re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*=.*", argument):
                index += 1
            else:
                break
        return _invocation_executes_apple_tests(arguments[index:])
    if executable == "xcrun":
        index = 0
        while index < len(arguments) and arguments[index].startswith("-"):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            if (
                argument in {"--find", "--help", "--version"} or argument.startswith("--show-")
                or not argument.startswith("--") and any(flag in argument[1:] for flag in "fh")
            ):
                return False
            index += 2 if argument in {"--sdk", "--toolchain"} else 1
        return _invocation_executes_apple_tests(arguments[index:])
    if any(argument in {"-h", "--help", "-help", "--version", "-version"} for argument in arguments):
        return False
    if executable == "simctl":
        index = 0
        while index < len(arguments) and arguments[index].startswith("-"):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            index += 2 if argument in {"--set", "--profiles"} else 1
        return index < len(arguments) and arguments[index] in {"create", "boot"}
    if executable == "swift":
        return "test" in arguments
    if executable == "xcodebuild":
        return any(a in {"test", "test-without-building", "build-for-testing"} for a in arguments)
    if executable == "xcodebuildmcp":
        if "-v" in arguments:
            return False
        # Global CLI flags may precede the workflow; inspect command positions.
        index = 0
        while index < len(arguments) and arguments[index].startswith("-"):
            argument = arguments[index]
            if argument == "--":
                index += 1
                break
            index += 2 if argument in {"--log-level", "--style", "--file-path-render-style", "--socket"} else 1
        command = arguments[index:index + 2]
        return len(command) == 2 and (
            command[0] in {"swift-package", "simulator", "device", "macos"} and command[1] == "test"
            or command[0] in {"simulator", "simulator-management"} and command[1] == "boot"
            or command == ["simulator", "build-and-run"]
        )
    return False


def _shell_commands(source: str) -> list[list[str]]:
    """Split unquoted controls before shlex removes word-quoting information."""
    source = source.replace("\\\n", "")
    commands: list[list[str]] = []
    quote: str | None = None
    start = index = 0
    word_start = True
    while index < len(source):
        character = source[index]
        if character == "\\" and quote != "'":
            index += 2
            word_start = False
            continue
        if quote is not None:
            if character == quote:
                quote = None
        elif character in "'\"":
            quote = character
        elif character == "#" and word_start:
            commands.append(shlex.split(source[start:index], posix=True))
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
            start = index
            word_start = True
            continue
        elif character in ";&|()\n":
            commands.append(shlex.split(source[start:index], posix=True))
            start = index + 1
            word_start = True
            index += 1
            continue
        word_start = quote is None and character in " \t\r"
        index += 1
    commands.append(shlex.split(source[start:], posix=True))
    return commands


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
