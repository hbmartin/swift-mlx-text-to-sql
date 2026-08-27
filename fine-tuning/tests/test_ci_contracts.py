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
    matches = []
    workflows = check_ci_contracts.ROOT / ".github" / "workflows"
    for path in (*workflows.glob("*.yml"), *workflows.glob("*.yaml")):
        workflow = yaml.safe_load(path.read_text())
        if (
            isinstance(workflow, dict)
            and workflow.get("name") == check_ci_contracts.ACCESSIBILITY_WORKFLOW_NAME
        ):
            matches.append((path, workflow))
    assert len(matches) == 1
    return matches[0]


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


def test_workflow_discovery_includes_yml_and_yaml(monkeypatch, tmp_path):
    (tmp_path / "ci.yml").write_text("name: CI\njobs: {}\n")
    (tmp_path / "security.yaml").write_text(
        "jobs:\n"
        "  test:\n"
        "    steps:\n"
        "      - uses: unsafe/action@main\n"
    )
    (tmp_path / "ignored.txt").write_text("uses: unsafe/action@main\n")
    monkeypatch.setattr(check_ci_contracts, "WORKFLOWS", tmp_path)
    monkeypatch.setattr(check_ci_contracts, "ROOT", tmp_path)

    with pytest.raises(SystemExit, match=r"security\.yaml:.*action is not SHA-pinned"):
        check_ci_contracts.main()


def test_accessibility_workflow_discovery_accepts_yaml_extension(
    monkeypatch, tmp_path
):
    source_path, _ = accessibility_workflow()
    (tmp_path / "renamed.yaml").write_text(source_path.read_text())
    monkeypatch.setattr(check_ci_contracts, "WORKFLOWS", tmp_path)
    monkeypatch.setattr(check_ci_contracts, "ROOT", tmp_path)

    check_ci_contracts.main()


def test_accessibility_workflow_discovery_rejects_missing_workflow(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(check_ci_contracts, "WORKFLOWS", tmp_path)
    monkeypatch.setattr(check_ci_contracts, "ROOT", tmp_path)

    with pytest.raises(SystemExit, match="exactly one workflow named 'CI'"):
        check_ci_contracts.main()


def test_accessibility_ui_ci_pins_runtime_and_preserves_result_bundle():
    path, workflow = accessibility_workflow()

    assert check_ci_contracts.accessibility_ui_contract_failures(path, workflow) == []


def test_accessibility_ui_contract_rejects_fragments_in_unrelated_steps():
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"]["swift"]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    fragment = "CREG_ACCESSIBILITY_HARNESS_BUILD=YES"
    ui_test["run"] = ui_test["run"].replace(fragment, "")
    steps.append({"name": "Unrelated documentation", "run": f"echo {fragment}"})

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert "UI test step is missing command fragments" in failures[0]
    assert fragment in failures[0]


@pytest.mark.parametrize(
    ("reviewed", "replacement"),
    [
        ("-project CREG.xcodeproj", "-project Decoy.xcodeproj"),
        ("-scheme CREG", "-scheme Decoy"),
        (
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=macOS,name=iPhone 17 Pro,OS=26.5",
        ),
    ],
)
def test_accessibility_ui_contract_pins_project_scheme_and_destination(
    reviewed, replacement
):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"]["swift"]["steps"]
    ui_test = next(
        step
        for step in steps
        if step.get("name") == "Test focused accessibility UI contracts"
    )
    ui_test["run"] = ui_test["run"].replace(reviewed, replacement)

    failures = check_ci_contracts.accessibility_ui_contract_failures(path, workflow)

    assert len(failures) == 1
    assert reviewed in failures[0]


@pytest.mark.parametrize("condition", ["always()", "${{ always() }}"])
def test_accessibility_ui_contract_accepts_equivalent_always_conditions(condition):
    path, workflow = accessibility_workflow()
    steps = workflow["jobs"]["swift"]["steps"]
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
