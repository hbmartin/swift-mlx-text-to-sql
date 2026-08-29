import json
import os
import plistlib
import subprocess
from pathlib import Path

import pytest
import yaml

from tools import check_ci_contracts


def failures(source: str) -> list[str]:
    path = check_ci_contracts.ROOT / ".github" / "workflows" / "fixture.yml"
    return check_ci_contracts.checkout_credential_failures(
        Path(path), yaml.safe_load(source)
    )


def run_materializer(environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/zsh",
            str(check_ci_contracts.ROOT / "tools/materialize_bundled_model.sh"),
        ],
        cwd=check_ci_contracts.ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def accessibility_workflow() -> tuple[Path, dict[str, object]]:
    matches = check_ci_contracts.accessibility_workflows()
    assert len(matches) == 1
    path, workflow = matches[0]
    assert isinstance(workflow, dict)
    return path, workflow


REVIEWED_RUN_CONTRACTS = (
    (
        check_ci_contracts.accessibility_ui_contract_failures,
        check_ci_contracts.ACCESSIBILITY_UI_JOB,
        "Test focused accessibility UI contracts",
    ),
    (
        check_ci_contracts.testflight_publisher_contract_failures,
        check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB,
        "Run TestFlight publisher tests",
    ),
)


def xcode_target_configurations(
    project_path: Path, target_name: str
) -> dict[str, dict[str, object]]:
    completed = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(project_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    project = json.loads(completed.stdout)
    objects = project["objects"]
    target = next(
        value
        for value in objects.values()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == target_name
    )
    configuration_list = objects[target["buildConfigurationList"]]
    return {
        objects[identifier]["name"]: objects[identifier]["buildSettings"]
        for identifier in configuration_list["buildConfigurations"]
    }


def test_checkout_credentials_are_read_from_the_checkout_with_mapping():
    assert (
        failures(
            """
jobs:
  test:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        with:
          fetch-depth: 2
          persist-credentials: false
"""
        )
        == []
    )


def test_unrelated_text_cannot_satisfy_checkout_credentials_contract():
    result = failures(
        """
jobs:
  test:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      # persist-credentials: false
      - run: |
          echo 'persist-credentials: false'
"""
    )

    assert len(result) == 1
    assert "persists credentials" in result[0]


def test_workflow_discovery_includes_yml_and_yaml(tmp_path):
    (tmp_path / "ci.yml").write_text("name: CI\njobs: {}\n")
    (tmp_path / "security.yaml").write_text(
        "jobs:\n"
        "  test:\n"
        "    steps:\n"
        "      - uses: unsafe/action@main\n"
    )
    (tmp_path / "ignored.txt").write_text("uses: unsafe/action@main\n")
    with pytest.raises(SystemExit, match=r"security\.yaml:.*action is not SHA-pinned"):
        check_ci_contracts.main(root=tmp_path, workflow_directory=tmp_path)


def test_accessibility_workflow_discovery_accepts_yaml_extension(tmp_path):
    source_path, _ = accessibility_workflow()
    (tmp_path / "renamed.yaml").write_text(source_path.read_text())
    check_ci_contracts.main(root=tmp_path, workflow_directory=tmp_path)


def test_accessibility_workflow_discovery_rejects_missing_workflow(tmp_path):
    with pytest.raises(SystemExit) as error:
        check_ci_contracts.main(root=tmp_path, workflow_directory=tmp_path)

    diagnostic = str(error.value)
    assert "exactly one workflow named 'CI'" in diagnostic
    assert str(tmp_path) in diagnostic
    assert not diagnostic.startswith(".:")


def test_accessibility_ui_ci_pins_runtime_and_preserves_result_bundle():
    path, workflow = accessibility_workflow()

    assert check_ci_contracts.accessibility_ui_contract_failures(path, workflow) == []


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("continue-on-error", True),
        ("env", {"PATH": "/tmp/decoy"}),
        ("if", False),
        ("shell", "/bin/echo {0}"),
        ("working-directory", "decoy"),
    ],
)
@pytest.mark.parametrize(
    ("validator", "job_name", "step_name"), REVIEWED_RUN_CONTRACTS
)
def test_reviewed_run_contracts_reject_step_execution_overrides(
    field, value, validator, job_name, step_name
):
    path, workflow = accessibility_workflow()
    step = next(
        candidate
        for candidate in workflow["jobs"][job_name]["steps"]
        if candidate.get("name") == step_name
    )
    step[field] = value

    failures = validator(path, workflow)

    assert len(failures) == 1
    assert field in failures[0]


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("continue-on-error", True),
        ("defaults", {"run": {"shell": "/bin/echo {0}"}}),
        ("env", {"PATH": "/tmp/decoy"}),
        ("if", False),
        ("needs", "skipped-job"),
        ("strategy", {"matrix": {"include": []}}),
        ("timeout-minutes", 1),
    ],
)
@pytest.mark.parametrize(
    ("validator", "job_name", "step_name"), REVIEWED_RUN_CONTRACTS
)
def test_reviewed_run_contracts_reject_job_execution_overrides(
    field, value, validator, job_name, step_name
):
    path, workflow = accessibility_workflow()
    workflow["jobs"][job_name][field] = value

    failures = validator(path, workflow)

    assert len(failures) == 1
    assert field in failures[0]


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("defaults", {"run": {"working-directory": "decoy"}}),
        ("env", {"PATH": "/tmp/decoy"}),
    ],
)
def test_reviewed_run_contracts_reject_workflow_execution_overrides(
    field, value
):
    path, workflow = accessibility_workflow()
    workflow[field] = value

    failures = check_ci_contracts.reviewed_workflow_context_failures(path, workflow)

    assert len(failures) == 1
    assert field in failures[0]


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("defaults", {"run": {"shell": "/usr/bin/true {0}"}}),
        ("env", {"BASH_ENV": "/tmp/exit-successfully"}),
    ],
)
def test_main_reports_a_workflow_context_override_once(tmp_path, field, value):
    _, workflow = accessibility_workflow()
    workflow[field] = value
    (tmp_path / "ci.yml").write_text(yaml.safe_dump(workflow, sort_keys=False))

    with pytest.raises(SystemExit) as error:
        check_ci_contracts.main(root=tmp_path, workflow_directory=tmp_path)

    assert str(error.value).count("workflow must not override") == 1


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("defaults", {"run": {"shell": "/usr/bin/true {0}"}}),
        ("env", {"BASH_ENV": "/tmp/exit-successfully"}),
    ],
)
def test_contract_checker_cannot_inherit_workflow_level_bypasses(field, value):
    path, workflow = accessibility_workflow()
    workflow[field] = value
    checker = next(
        step
        for step in workflow["jobs"]["security"]["steps"]
        if step.get("name") == "Verify workflow action pins"
    )
    setup_uv = next(
        step
        for step in workflow["jobs"]["security"]["steps"]
        if step.get("id") == "setup-security-uv"
    )

    assert setup_uv["env"] == check_ci_contracts.SETUP_UV_ENV
    assert checker["shell"] == check_ci_contracts.UBUNTU_REVIEWED_RUN_SHELL
    assert checker["working-directory"] == (
        "${{ github.workspace }}/fine-tuning"
    )
    assert check_ci_contracts.reviewed_workflow_context_failures(
        path, workflow
    )


@pytest.mark.parametrize(
    ("validator", "job_name", "step_name"), REVIEWED_RUN_CONTRACTS
)
def test_reviewed_run_contracts_pin_the_runner(validator, job_name, step_name):
    path, workflow = accessibility_workflow()
    expected_runner = (
        check_ci_contracts.ACCESSIBILITY_UI_RUNNER
        if job_name == check_ci_contracts.ACCESSIBILITY_UI_JOB
        else check_ci_contracts.TESTFLIGHT_PUBLISHER_RUNNER
    )
    workflow["jobs"][job_name]["runs-on"] = "decoy-runner"

    failures = validator(path, workflow)

    assert len(failures) == 1
    assert f"must run on {expected_runner}" in failures[0]


@pytest.mark.parametrize(
    "predecessor",
    [
        {
            "name": "Mutate PATH",
            "run": 'printf "%s\\n" /tmp/decoy >> "$GITHUB_PATH"',
        },
        {
            "name": "Mutate shell startup",
            "run": (
                "python -c \"import os; open(os.environ['GITHUB_ENV'], 'a').write("
                "'BASH_ENV=/tmp/hook\\\\n')\""
            ),
        },
        {
            "name": "Run unchecked repository code",
            "run": "python unreviewed_helper.py",
        },
    ],
)
@pytest.mark.parametrize(
    ("validator", "job_name", "step_name"), REVIEWED_RUN_CONTRACTS
)
def test_reviewed_run_contracts_reject_unreviewed_predecessors(
    predecessor, validator, job_name, step_name
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][job_name]["steps"]
    target_index = next(
        index for index, step in enumerate(steps) if step.get("name") == step_name
    )
    steps.insert(target_index, predecessor)

    failures = validator(path, workflow)

    assert len(failures) == 1
    assert "bootstrap" in failures[0] or "unexpected predecessor" in failures[0]


@pytest.mark.parametrize(
    ("validator", "job_name", "step_name"), REVIEWED_RUN_CONTRACTS
)
def test_reviewed_run_contracts_allow_post_target_steps(
    validator, job_name, step_name
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][job_name]["steps"]
    target_index = next(
        index for index, step in enumerate(steps) if step.get("name") == step_name
    )
    steps.insert(
        target_index + 1,
        {"name": "Post-target cleanup", "run": "printf cleanup"},
    )

    assert validator(path, workflow) == []


@pytest.mark.parametrize(
    ("field", "value"),
    [("version", "latest"), ("checksum", "0" * 64)],
)
def test_testflight_bootstrap_pins_the_setup_uv_download(field, value):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB]["steps"]
    setup_uv = next(step for step in steps if step.get("name") == "Install uv")
    setup_uv["with"][field] = value

    failures = check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    )

    assert len(failures) == 1
    assert "unreviewed bootstrap" in failures[0]


def test_accessibility_ui_contract_rejects_fragments_in_unrelated_steps():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    fragment = "CREG_ACCESSIBILITY_HARNESS_BUILD=YES"
    final_continuation = " " + "\\" + "\n  " + fragment + "\n"
    ui_test["run"] = ui_test["run"].replace(
        final_continuation, "\n"
    )
    steps.append({"name": "Unrelated documentation", "run": f"echo {fragment}"})

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "UI test command argument errors" in failures[0]
    assert fragment in failures[0]


@pytest.mark.parametrize(
    ("reviewed", "replacement", "expected"),
    [
        (
            "-project CREG.xcodeproj",
            "-project Decoy.xcodeproj",
            "CREG.xcodeproj",
        ),
        (
            "-project CREG.xcodeproj",
            "-project CREG.xcodeproj.backup",
            "CREG.xcodeproj",
        ),
        ("-scheme CREG", "-scheme Decoy", "CREG"),
        ("-scheme CREG", "-scheme CREGPreview", "CREG"),
        (
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=macOS,name=iPhone 17 Pro,OS=26.5",
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
        ),
        (
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5beta",
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
        ),
    ],
)
def test_accessibility_ui_contract_pins_project_scheme_and_destination(
    reviewed, replacement, expected
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(reviewed, replacement)

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert f"must be {expected!r}" in failures[0]


def test_accessibility_ui_contract_accepts_a_wrapped_flag_value_pair():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(
        "-project CREG.xcodeproj", "-project \\\n            CREG.xcodeproj"
    )

    assert check_ci_contracts.accessibility_ui_contract_failures(path, workflow) == []


def test_accessibility_ui_contract_rejects_a_crlf_wrapped_flag_value_pair():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(
        "-project CREG.xcodeproj", "-project \\\r\n            CREG.xcodeproj"
    )

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "must contain exactly one shell command" in failures[0]


def test_accessibility_ui_contract_accepts_a_wrapped_former_fragment_pair():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(
        '-derivedDataPath "${{ runner.temp }}/creg-derived-data"',
        '-derivedDataPath \\\n            "${{ runner.temp }}/creg-derived-data"',
    )

    assert check_ci_contracts.accessibility_ui_contract_failures(path, workflow) == []


@pytest.mark.parametrize("decoy_kind", ["comment", "quoted argument"])
def test_accessibility_ui_contract_rejects_inert_required_fragments(decoy_kind):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    inert_fragments = " ".join(
        (
            '-clonedSourcePackagesDirPath "${{ runner.temp }}/creg-source-packages"',
            '-derivedDataPath "${{ runner.temp }}/creg-derived-data"',
            '-resultBundlePath "${{ runner.temp }}/creg-accessibility-ui-tests.xcresult"',
            "-skipPackagePluginValidation",
            "-only-testing:CREGUITests/AccessibilityUITests/"
            "testHighestRiskScreensAtAX5Landscape",
            "-only-testing:CREGUITests/AccessibilityUITests/"
            "testMalformedConfigurationRendersInvalidConfigurationScreen",
            "-only-testing:CREGUITests/AccessibilityUITests/"
            "testChartPreparationHasDistinctIdentityInProductionPresentation",
            "CREG_ACCESSIBILITY_HARNESS_BUILD=YES",
        )
    )
    reviewed_prefix = (
        "/usr/bin/xcodebuild test -project CREG.xcodeproj -scheme CREG "
        "-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'"
    )
    ui_test["run"] = (
        f"{reviewed_prefix} # {inert_fragments}"
        if decoy_kind == "comment"
        else f"{reviewed_prefix} '{inert_fragments}'"
    )

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "UI test command argument errors" in failures[0]
    assert "-clonedSourcePackagesDirPath" in failures[0]


@pytest.mark.parametrize(
    ("reviewed", "duplicate", "flag"),
    [
        ("-project CREG.xcodeproj", "-project Decoy.xcodeproj", "-project"),
        ("-scheme CREG", "-scheme Decoy", "-scheme"),
        (
            "-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'",
            "-destination 'platform=macOS'",
            "-destination",
        ),
    ],
)
def test_accessibility_ui_contract_rejects_duplicate_pinned_arguments(
    reviewed, duplicate, flag
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(
        reviewed, f"{reviewed} {duplicate}"
    )

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert f"found {flag!r}" in failures[0]


def test_accessibility_ui_contract_requires_a_direct_xcodebuild_invocation():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(
        "/usr/bin/xcodebuild test", "env /usr/bin/xcodebuild test", 1
    )

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "must run xcodebuild test directly" in failures[0]


@pytest.mark.parametrize(
    ("suffix", "diagnostic"),
    [
        (" $(printf inert)", "shell command substitutions"),
        (" `printf inert`", "shell command substitutions"),
        (" > build.log", "shell redirections"),
        ("\N{NO-BREAK SPACE}# ; printf second-command", "shell control operators"),
        (
            " CREG_ACCESSIBILITY_HARNESS_BUILD=NO",
            "UI test command argument errors",
        ),
        (
            " -skip-testing:CREGUITests/AccessibilityUITests/"
            "testHighestRiskScreensAtAX5Landscape",
            "UI test command argument errors",
        ),
    ],
)
def test_accessibility_ui_contract_rejects_unsafe_or_unreviewed_suffixes(
    suffix, diagnostic
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].rstrip() + suffix

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert diagnostic in failures[0]


@pytest.mark.parametrize("line_ending", ["\n", "\r\n"])
def test_accessibility_ui_contract_rejects_a_command_after_a_continued_comment(
    line_ending,
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = (
        ui_test["run"].rstrip()
        + f" # \\{line_ending}printf second-command"
    )

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "must contain exactly one shell command" in failures[0]


@pytest.mark.parametrize(
    "value",
    [
        "${{ runner.temp }}/creg-source-packages",
        "${{ runner.temp }}/creg-derived-data",
        "${{ runner.temp }}/creg-accessibility-ui-tests.xcresult",
    ],
)
def test_accessibility_ui_contract_requires_quoted_runner_paths(value):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(f'"{value}"', value)

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "runner paths must be double-quoted" in failures[0]
    assert value in failures[0]


def test_accessibility_ui_contract_reports_a_missing_final_flag_value():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = "/usr/bin/xcodebuild test -project"

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "missing token 4" in failures[0]
    assert "CREG.xcodeproj" in failures[0]


@pytest.mark.parametrize("operator", [";", "&", "|"])
def test_shell_parser_accepts_quoted_control_operator(operator):
    command = check_ci_contracts._parse_single_shell_command(f"echo '{operator}'")

    assert command.tokens == ("echo", operator)


@pytest.mark.parametrize("operator", [";", "&", "|"])
def test_shell_parser_rejects_unquoted_control_operator(operator):
    with pytest.raises(ValueError, match="shell control operators"):
        check_ci_contracts._parse_single_shell_command(
            f"echo reviewed {operator} echo decoy"
        )


@pytest.mark.parametrize(
    ("source", "diagnostic"),
    [
        ("echo $(printf decoy)", "shell command substitutions"),
        ("echo `printf decoy`", "shell command substitutions"),
        ("echo < input", "shell redirections"),
        ("echo 2> output", "shell redirections"),
        ("echo (printf decoy)", "shell control operators"),
    ],
)
def test_shell_parser_rejects_active_shell_syntax(source, diagnostic):
    with pytest.raises(ValueError, match=diagnostic):
        check_ci_contracts._parse_single_shell_command(source)


@pytest.mark.parametrize("continuations", ["\\\n", "\\\n\\\n"])
def test_shell_parser_rejects_a_continued_double_quoted_substitution(continuations):
    source = f'printf "%s" "${continuations}(printf decoy)"'

    with pytest.raises(ValueError, match="shell command substitutions"):
        check_ci_contracts._parse_single_shell_command(source)


def test_shell_parser_accepts_an_escaped_continued_dollar():
    command = check_ci_contracts._parse_single_shell_command(
        'printf "%s" "\\$\\\n(quoted data)"'
    )

    assert command.tokens == ("printf", "%s", "\\$(quoted data)")


def test_shell_parser_accepts_quoted_newline_and_syntax():
    command = check_ci_contracts._parse_single_shell_command(
        "printf '%s' 'first\n$(second); > output'"
    )

    assert command.tokens == ("printf", "%s", "first\n$(second); > output")


def test_shell_parser_reports_unterminated_multiline_quote():
    with pytest.raises(ValueError, match="No closing quotation"):
        check_ci_contracts._parse_single_shell_command("printf 'first\nsecond")


def test_accessibility_ui_contract_rejects_arguments_in_a_decoy_command():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    reviewed_arguments = (
        "/usr/bin/xcodebuild test -project CREG.xcodeproj -scheme CREG "
        "-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'"
    )
    decoy_command = (
        ui_test["run"]
        .replace("CREG.xcodeproj", "Decoy.xcodeproj")
        .replace("-scheme CREG", "-scheme Decoy")
        .replace(
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=macOS",
        )
    )
    ui_test["run"] = f": {reviewed_arguments}; {decoy_command}"

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "shell command is malformed" in failures[0]


def test_accessibility_ui_contract_reports_only_the_shell_parse_failure():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].rstrip() + "'"

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "shell command is malformed" in failures[0]
    assert "No closing quotation" in failures[0]


def test_ci_runs_testflight_publisher_contract_tests_with_python_3_13():
    path, workflow = accessibility_workflow()

    assert check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    ) == []


def test_testflight_publisher_contract_requires_a_quoted_discovery_pattern():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB]["steps"]
    publisher_test = next(
        step
        for step in steps
        if step.get("name") == "Run TestFlight publisher tests"
    )
    publisher_test["run"] = publisher_test["run"].replace(
        "'test_*.py'", "test_*.py"
    )

    failures = check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    )

    assert len(failures) == 1
    assert "test discovery pattern must be single-quoted" in failures[0]


def test_testflight_publisher_contract_rejects_a_continued_comment_command():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB]["steps"]
    publisher_test = next(
        step
        for step in steps
        if step.get("name") == "Run TestFlight publisher tests"
    )
    publisher_test["run"] = (
        publisher_test["run"].rstrip() + " # \\\nprintf second-command"
    )

    failures = check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    )

    assert len(failures) == 1
    assert "must contain exactly one shell command" in failures[0]


@pytest.mark.parametrize(
    ("reviewed", "replacement", "diagnostic"),
    [
        (
            "run --no-project --managed-python --python 3.13",
            "python3",
            "token 4 must be 'run', found 'python3'",
        ),
        (
            "--python 3.13",
            "--python 3.12",
            "token 8 must be '3.13', found '3.12'",
        ),
        (
            ".agents/skills/publish-creg-testflight/tests",
            ".agents/skills/decoy/tests",
            "token 14 must be '.agents/skills/publish-creg-testflight/tests', "
            "found '.agents/skills/decoy/tests'",
        ),
    ],
)
def test_testflight_publisher_contract_rejects_unreviewed_commands(
    reviewed, replacement, diagnostic
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB]["steps"]
    publisher_test = next(
        step
        for step in steps
        if step.get("name") == "Run TestFlight publisher tests"
    )
    publisher_test["run"] = publisher_test["run"].replace(reviewed, replacement)

    failures = check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    )

    assert len(failures) == 1
    assert "uv-managed Python 3.13" in failures[0]
    assert diagnostic in failures[0]


def test_testflight_publisher_contract_rejects_a_missing_step():
    path, workflow = accessibility_workflow()
    job = workflow["jobs"][check_ci_contracts.TESTFLIGHT_PUBLISHER_JOB]
    steps = job["steps"]
    job["steps"] = [
        step
        for step in steps
        if step.get("name") != "Run TestFlight publisher tests"
    ]

    failures = check_ci_contracts.testflight_publisher_contract_failures(
        path, workflow
    )

    assert len(failures) == 1
    assert "requires exactly one" in failures[0]


@pytest.mark.parametrize("condition", ["always()", "${{ always() }}"])
def test_accessibility_ui_contract_accepts_equivalent_always_conditions(condition):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"][check_ci_contracts.ACCESSIBILITY_UI_JOB]["steps"]
    upload = next(
        step
        for step in steps
        if step.get("name") == "Upload accessibility UI test results"
    )
    upload["if"] = condition

    assert check_ci_contracts.accessibility_ui_contract_failures(path, workflow) == []


@pytest.mark.parametrize("enabled_value", ["1", "YES", "true", "ON"])
def test_accessibility_harness_bypass_clears_artifacts_and_stamps_provenance(
    tmp_path, enabled_value
):
    target_build_dir = tmp_path / "Debug-iphonesimulator"
    resource_dir = target_build_dir / "CREG.app"
    model_dir = resource_dir / "SQLModel"
    model_dir.mkdir(parents=True)
    (model_dir / "stale.safetensors").write_text("stale")
    (resource_dir / "model-manifest.json").write_text("stale")
    (resource_dir / "production-model-receipt.json").write_text("stale")
    info_path = resource_dir / "Info.plist"
    with info_path.open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "dev.haroldmartin.CREG"}, stream)

    environment = os.environ.copy()
    environment.update(
        {
            "CREG_ACCESSIBILITY_HARNESS_BUILD": enabled_value,
            "CONFIGURATION": "Debug",
            "PLATFORM_NAME": "iphonesimulator",
            "SRCROOT": str(check_ci_contracts.ROOT),
            "TARGET_BUILD_DIR": str(target_build_dir),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "CREG.app",
            "INFOPLIST_PATH": "CREG.app/Info.plist",
        }
    )

    completed = run_materializer(environment)

    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "stale model artifacts were cleared" in completed.stdout
    assert not model_dir.exists()
    assert not (resource_dir / "model-manifest.json").exists()
    assert not (resource_dir / "production-model-receipt.json").exists()
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    contract = json.loads(
        (check_ci_contracts.ROOT / "model-runtime-contract.json").read_text()
    )
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=check_ci_contracts.ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    dirty = bool(
        subprocess.run(
            [
                "git",
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignore-submodules=none",
            ],
            cwd=check_ci_contracts.ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    assert info["CREGModelRuntimeContractVersion"] == contract["current_version"]
    assert info["CREGSourceRevision"] == revision
    assert info["CREGSourceDirty"] is dirty


def test_accessibility_harness_bypass_rejects_unknown_boolean_value():
    environment = os.environ.copy()
    environment["CREG_ACCESSIBILITY_HARNESS_BUILD"] = "sometimes"

    completed = run_materializer(environment)

    assert completed.returncode == 1
    assert "must be a Boolean" in completed.stdout
    assert "unbound variable" not in completed.stderr


@pytest.mark.parametrize("disabled_value", ["", "0", "NO", "false", "OFF"])
def test_accessibility_harness_false_values_do_not_enable_the_bypass(
    disabled_value,
):
    environment = os.environ.copy()
    environment["CREG_ACCESSIBILITY_HARNESS_BUILD"] = disabled_value

    completed = run_materializer(environment)

    assert completed.returncode == 1
    assert "requires the Xcode build environment" in completed.stdout
    assert "UI-test harness build omits" not in completed.stdout


@pytest.mark.parametrize(
    ("configuration", "platform"),
    [
        ("", ""),
        ("Beta", "iphoneos"),
        ("Release", "iphoneos"),
        ("Debug", "iphoneos"),
    ],
)
def test_accessibility_harness_bypass_rejects_non_debug_simulator_scope(
    configuration, platform
):
    environment = os.environ.copy()
    environment.update(
        {
            "CREG_ACCESSIBILITY_HARNESS_BUILD": "YES",
            "CONFIGURATION": configuration,
            "PLATFORM_NAME": platform,
        }
    )

    completed = run_materializer(environment)

    assert completed.returncode == 1
    assert "restricted to Debug iOS Simulator builds" in completed.stdout
    assert "unbound variable" not in completed.stderr


def test_xcode_debug_candidate_is_explicit_and_release_remains_production_only():
    project_path = check_ci_contracts.ROOT / "CREG.xcodeproj/project.pbxproj"
    project = project_path.read_text()
    materializer = (
        check_ci_contracts.ROOT / "tools/materialize_bundled_model.sh"
    ).read_text()
    assert "Materialize Bundled SQL Model" in project
    assert "tools/materialize_bundled_model.sh" in project
    assert "model-runtime-contract.json" in project
    configurations = xcode_target_configurations(project_path, "CREG")
    assert set(configurations) == {"Debug", "Beta", "Release"}
    assert all(
        settings.get("CREG_ACCESSIBILITY_HARNESS_BUILD") == "NO"
        for settings in configurations.values()
    )
    assert project.count('CREG_CANDIDATE_TRAINING_RUN = "latest-local-v3";') == 2
    assert "CREG_DEBUG_TRAINING_RUN" not in project
    assert "CREG_EXPERIMENTAL_TRAINING_RUN" not in project
    assert "--production" in materializer
    assert "--models-dir" in materializer
    assert '--destination "$MODEL_DIR"' in materializer
    assert "--local-files-only" not in materializer
    assert "--allow-historical-policy" in materializer
    assert (
        '"$CONFIGURATION_VALUE" == "Debug" || "$CONFIGURATION_VALUE" == "Beta"'
        in materializer
    )
    assert "1 | yes | true | on" in materializer
    assert 'CREG_ACCESSIBILITY_HARNESS_BUILD must be a Boolean' in materializer
    assert '/bin/rm -rf -- "$MODEL_DIR"' in materializer
    assert "tools/materialize_debug_model.py" in materializer
    assert "--latest-local-v3" in materializer
    assert "CREG_CANDIDATE_TRAINING_RUN is forbidden in Release builds" in materializer
    assert "without requiring a W&B receipt" in materializer

    live_dependencies = (
        check_ci_contracts.ROOT
        / "CREGKit/Sources/CREGApplication/LiveDependencies.swift"
    ).read_text()
    assert "ProductionModelReceiptLoader.validate" in live_dependencies
    for setting in (
        "directory: bundledModelDirectory",
        "useWiredMemory: useWiredMemory",
        "useDirectPromptSuffix: true",
        "metalCommandBufferLimitMB: production.metalCommandBufferLimitMB",
        "compiledQwen2MLPFusion: production.compiledQwen2MLPFusion",
        "verificationMLPSkipLayers: production.verificationMLPSkipLayers",
        "questionAwareOutputHead: production.questionAwareOutputHead",
        "productionNGramSpeculation: production.sqlNGramSpeculation",
        "runtimeMode: .evaluated",
    ):
        assert setting in live_dependencies
    assert '"input_preparation_mode"' in (
        check_ci_contracts.ROOT
        / "CREGKit/Sources/CREGInference/MLXSQLGenerator.swift"
    ).read_text()
    assert "#if DEBUG || CREG_DEVICE_BENCHMARK" in live_dependencies
    assert 'environment["CREG_WIRED_MEMORY"] == "true"' in live_dependencies
    assert "let useWiredMemory = false" in live_dependencies
    assert "SQLGenClient.live(model:" not in live_dependencies
    build_channel = (
        check_ci_contracts.ROOT
        / "CREGKit/Sources/CREGFeatures/ModelPreparationSupport.swift"
    ).read_text()
    assert "Release requires schema-v3 bounded-policy evidence" in build_channel
    assert "Release refuses Debug candidate model identities" in build_channel


def test_xcode_app_is_iphone_only():
    project = (check_ci_contracts.ROOT / "CREG.xcodeproj/project.pbxproj").read_text()
    app_icons = (
        check_ci_contracts.ROOT
        / "CREG/Assets.xcassets/Contents.json"
    ).read_text()

    # Every declared target configuration stays iPhone-only.
    assert project.count("TARGETED_DEVICE_FAMILY = 1;") >= 3
    assert 'TARGETED_DEVICE_FAMILY = "1,2";' not in project
    assert "UISupportedInterfaceOrientations_iPad" not in project
    assert '"idiom" : "ipad"' not in app_icons
