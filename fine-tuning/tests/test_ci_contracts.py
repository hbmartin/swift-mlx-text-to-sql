from pathlib import Path

import pytest
import yaml

from tools import check_ci_contracts


def failures(source: str) -> list[str]:
    path = check_ci_contracts.ROOT / ".github" / "workflows" / "fixture.yml"
    return check_ci_contracts.checkout_credential_failures(
        Path(path), yaml.safe_load(source)
    )


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
    (tmp_path / "ci.yml").write_text("jobs: {}\n")
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


def test_accessibility_ui_ci_pins_runtime_and_preserves_result_bundle():
    workflow = (check_ci_contracts.ROOT / ".github/workflows/ci.yml").read_text()

    assert "name=iPhone 17 Pro,OS=26.5" in workflow
    assert (
        '-resultBundlePath "${RUNNER_TEMP}/creg-accessibility-ui-tests.xcresult"'
        in workflow
    )
    assert (
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
        in workflow
    )
    assert (
        "path: ${{ runner.temp }}/creg-accessibility-ui-tests.xcresult" in workflow
    )


def test_xcode_debug_candidate_is_explicit_and_release_remains_production_only():
    project = (check_ci_contracts.ROOT / "CREG.xcodeproj/project.pbxproj").read_text()
    materializer = (
        check_ci_contracts.ROOT / "tools/materialize_bundled_model.sh"
    ).read_text()
    assert "Materialize Bundled SQL Model" in project
    assert "tools/materialize_bundled_model.sh" in project
    assert "model-runtime-contract.json" in project
    assert project.count('CREG_CANDIDATE_TRAINING_RUN = "latest-local-v3";') == 2
    assert "CREG_DEBUG_TRAINING_RUN" not in project
    assert "CREG_EXPERIMENTAL_TRAINING_RUN" not in project
    assert "--production" in materializer
    assert "--models-dir" in materializer
    assert '--destination "$MODEL_DIR"' in materializer
    assert "--local-files-only" not in materializer
    assert "--allow-historical-policy" in materializer
    assert '"$CONFIGURATION" == "Debug" || "$CONFIGURATION" == "Beta"' in materializer
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
