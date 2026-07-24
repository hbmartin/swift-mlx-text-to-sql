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


def test_xcode_debug_candidate_is_explicit_and_release_remains_production_only():
    project = (check_ci_contracts.ROOT / "CREG.xcodeproj/project.pbxproj").read_text()
    assert "Materialize Bundled SQL Model" in project
    assert "--production" in project
    assert "--models-dir" in project
    assert '--destination \\"$MODEL_DIR\\"' in project
    assert "--local-files-only" not in project
    assert "--allow-historical-policy" in project
    assert 'if [[ \\"$CONFIGURATION\\" == \\"Debug\\" ]]' in project
    assert "tools/materialize_debug_model.py" in project
    assert "--latest-local-v3" in project
    assert 'CREG_DEBUG_TRAINING_RUN = "latest-local-v3";' in project
    assert "CREG_DEBUG_TRAINING_RUN is forbidden outside Debug builds" in project
    assert "without requiring a W&B receipt" in project

    live_dependencies = (
        check_ci_contracts.ROOT
        / "CREGKit/Sources/CREGFeatures/ChatFeature.swift"
    ).read_text()
    assert "ProductionModelReceiptLoader.validate" in live_dependencies
    assert "SQLGenClient.live(directory: bundledModelDirectory)" in live_dependencies
    assert "SQLGenClient.live(model:" not in live_dependencies
    assert "#if !DEBUG" in live_dependencies
    assert "Release requires schema-v3 bounded-policy evidence" in live_dependencies
    assert "Release refuses Debug candidate model identities" in live_dependencies
