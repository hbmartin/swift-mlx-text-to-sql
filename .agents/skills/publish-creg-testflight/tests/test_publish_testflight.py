from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "publish_testflight.py"
REPO_ROOT = SCRIPT.parents[4]
MISSING = object()
SOURCE_REVISION = "a" * 40


def load_publisher() -> ModuleType:
    spec = importlib.util.spec_from_file_location("publish_testflight", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load publisher script: {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load_publisher()


def xcode_project(
    harness_settings: dict[str, str],
    *,
    decoy_settings: tuple[str, ...] = (),
) -> dict[str, Any]:
    objects: dict[str, Any] = {
        "target": {
            "isa": "PBXNativeTarget",
            "name": publisher.TARGET,
            "buildConfigurationList": "target-configurations",
        },
        "target-configurations": {
            "isa": "XCConfigurationList",
            "buildConfigurations": list(harness_settings),
        },
    }
    for name, value in harness_settings.items():
        objects[name] = {
            "isa": "XCBuildConfiguration",
            "name": name,
            "buildSettings": {"CREG_ACCESSIBILITY_HARNESS_BUILD": value},
        }
    for index, value in enumerate(decoy_settings):
        objects[f"decoy-{index}"] = {
            "isa": "XCBuildConfiguration",
            "name": f"Decoy {index}",
            "buildSettings": {"CREG_ACCESSIBILITY_HARNESS_BUILD": value},
        }
    return {"objects": objects}


def shell_script_phase(
    script: str,
    *,
    name: str = "Materialize Bundled SQL Model",
    input_paths: object = MISSING,
) -> dict[str, Any]:
    phase: dict[str, Any] = {
        "isa": "PBXShellScriptBuildPhase",
        "name": name,
        "shellScript": script,
        **dict(publisher.REVIEWED_SHELL_PHASE_ATTRIBUTES),
    }
    if input_paths is not MISSING:
        phase["inputPaths"] = input_paths
    return phase


def inspector_report(
    archive_build: object = MISSING,
    ipa_build: object = MISSING,
) -> dict[str, Any]:
    model = {
        "key": "model",
        "expected_directory_sha256": "model-digest",
        "verified_directory_sha256": "model-digest",
        "receipt_directory_sha256": "receipt-digest",
        "verified_file_count": 1,
        "receipt_file_count": 1,
    }

    def artifact(kind: str, build_number: object) -> dict[str, Any]:
        value: dict[str, Any] = {
            "artifact_kind": kind,
            "bundle_identifier": publisher.BUNDLE_IDENTIFIER,
            "marketing_version": "1.0",
            "build_channel": publisher.BUILD_CHANNEL,
            "model_runtime_contract": {
                "version": 1,
                "source_revision": SOURCE_REVISION,
                "source_dirty": False,
            },
            "production": {"model_key": "model"},
            "debug_candidate": {
                "model_key": "model",
                "base_model_key": "base",
                "training_run_id": "training-run",
                "selected_iteration": 600,
                "selected_checkpoint_sha256": "b" * 64,
                "local_evidence_status": "complete",
                "wandb_receipt_required": False,
            },
            "model": model.copy(),
            "executable": {
                "relative_path": "CREG",
                "signed_bytes": 10,
                "signed_sha256": ("c" if kind == "archive" else "9") * 64,
                "unsigned_bytes": 8,
                "unsigned_sha256": "8" * 64,
            },
            "code_signature": {"status": "valid"},
            "metal": {"sha256": "d" * 64, "bytes": 5},
            "inputs": {
                "bundled_manifest_sha256": "e" * 64,
                "production_receipt_sha256": "f" * 64,
            },
        }
        if build_number is not MISSING:
            value["build_number"] = build_number
        return value

    return {
        "schema_version": 3,
        "status": "complete",
        "configuration": publisher.CONFIGURATION,
        "artifacts": [
            artifact("archive", archive_build),
            artifact("ipa", ipa_build),
        ],
    }


class VerifyModelInputsTests(unittest.TestCase):
    def test_rejects_non_object_manifest_sections_with_release_errors(self) -> None:
        invalid_sections = (
            ("outputs", [], "Training manifest outputs"),
            (
                "checkpoint_evaluation",
                "invalid",
                "Training manifest checkpoint_evaluation",
            ),
            (
                "selected",
                [],
                "Training manifest checkpoint_evaluation.selected",
            ),
            ("experiment", None, "Training manifest experiment"),
        )
        for section, invalid_value, description in invalid_sections:
            manifest: dict[str, Any] = {
                "run_id": "training-run",
                "outputs": {"adapter": "models/adapters/training-run"},
                "checkpoint_evaluation": {
                    "selected": {
                        "checkpoint_path": (
                            "models/adapters/training-run/model.safetensors"
                        )
                    }
                },
                "experiment": {"model_key": "model"},
            }
            if section == "selected":
                manifest["checkpoint_evaluation"]["selected"] = invalid_value
            else:
                manifest[section] = invalid_value

            with (
                self.subTest(section=section),
                patch.object(publisher, "require_directory"),
                patch.object(publisher, "require_file"),
                patch.object(publisher, "load_json", return_value=manifest),
                self.assertRaises(publisher.ReleaseError) as caught,
            ):
                publisher.verify_model_inputs(Path("/repo"), "training-run")

            self.assertEqual(str(caught.exception), f"{description} must be an object")


class VerifyCandidateInputsTests(unittest.TestCase):
    def test_latest_selector_runs_the_real_candidate_preflight(self) -> None:
        payload = {
            "status": "debug_candidate_preflight_complete",
            "training_run_id": "resolved-run",
            "selected_iteration": 600,
            "selected_checkpoint_sha256": "b" * 64,
        }
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(payload), stderr=""
        )
        with patch.object(publisher, "run_command", return_value=completed) as run:
            result = publisher.verify_candidate_inputs(
                Path("/repo"),
                "latest-local-v3",
                uv="uv",
                log_path=Path("/tmp/candidate.log"),
            )

        command = run.call_args.args[0]
        self.assertIn("--latest-local-v3", command)
        self.assertIn("--preflight", command)
        self.assertEqual(result["training_run_id"], "resolved-run")
        self.assertEqual(result["candidate_selector"], "latest-local-v3")

    def test_latest_selector_rejects_an_incomplete_preflight(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout='{"status":"incomplete"}', stderr=""
        )
        with (
            patch.object(publisher, "run_command", return_value=completed),
            self.assertRaisesRegex(
                publisher.ReleaseError, "Candidate preflight did not complete"
            ),
        ):
            publisher.verify_candidate_inputs(
                Path("/repo"),
                "latest-local-v3",
                uv="uv",
                log_path=Path("/tmp/candidate.log"),
            )


class TargetBuildSettingTests(unittest.TestCase):
    def test_real_project_passes_the_production_source_contract(self) -> None:
        publisher.verify_source_contract(SCRIPT.parents[4])

    def test_missing_project_raises_a_release_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(
                publisher.ReleaseError, "Missing Xcode project file"
            ):
                publisher.load_xcode_project(Path(directory))

    def test_project_parse_failure_preserves_the_plutil_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            project_path = repo / publisher.PROJECT_FILE
            project_path.parent.mkdir(parents=True)
            project_path.write_text("malformed")
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=1,
                stdout="",
                stderr="Unexpected character at line 1",
            )

            with (
                patch.object(publisher, "run_command", return_value=completed),
                self.assertRaisesRegex(
                    publisher.ReleaseError, "Unexpected character at line 1"
                ),
            ):
                publisher.load_xcode_project(repo)

    def test_project_loader_requests_raw_machine_readable_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            project_path = repo / publisher.PROJECT_FILE
            project_path.parent.mkdir(parents=True)
            project_path.write_text("project")
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps({"objects": {}}),
                stderr="",
            )

            with patch.object(
                publisher, "run_command", return_value=completed
            ) as run_command:
                publisher.load_xcode_project(repo)

            self.assertTrue(run_command.call_args.kwargs["preserve_stdout"])

    def test_machine_readable_stdout_is_not_sanitized_before_parsing(self) -> None:
        raw_stdout = json.dumps(
            {"objects": {"phase": {"shellScript": "export API_KEY=secret"}}}
        )
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=raw_stdout,
            stderr="token=secret",
        )

        with patch.object(publisher.subprocess, "run", return_value=completed):
            result = publisher.run_command(
                ["plutil"],
                cwd=Path("/repo"),
                preserve_stdout=True,
            )

        self.assertEqual(result.stdout, raw_stdout)
        self.assertEqual(result.stderr, "token=[REDACTED]")

    def test_accepts_the_setting_on_every_target_configuration(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO", "Release": "NO"})

        publisher.require_target_build_setting(
            project,
            target_name=publisher.TARGET,
            setting="CREG_ACCESSIBILITY_HARNESS_BUILD",
            expected="NO",
            required_configurations=("Debug", "Beta", "Release"),
        )

    def test_only_validates_the_requested_configuration(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO", "Release": "NO"})
        project["objects"]["Debug"]["buildSettings"]["CREG_BUILD_CHANNEL"] = "debug"
        project["objects"]["Beta"]["buildSettings"]["CREG_BUILD_CHANNEL"] = "beta"
        project["objects"]["Release"]["buildSettings"]["CREG_BUILD_CHANNEL"] = (
            "release"
        )

        publisher.require_target_build_setting(
            project,
            target_name=publisher.TARGET,
            setting="CREG_BUILD_CHANNEL",
            expected="beta",
            required_configurations=("Beta",),
        )

    def test_all_configuration_validation_rejects_an_unlisted_bypass(self) -> None:
        project = xcode_project(
            {"Debug": "NO", "Beta": "NO", "Release": "NO", "Staging": "YES"}
        )

        with self.assertRaisesRegex(publisher.ReleaseError, r"Staging='YES'"):
            publisher.require_target_build_setting(
                project,
                target_name=publisher.TARGET,
                setting="CREG_ACCESSIBILITY_HARNESS_BUILD",
                expected="NO",
                required_configurations=("Debug", "Beta", "Release"),
                validate_all_configurations=True,
            )

    def test_decoy_occurrences_cannot_hide_a_wrong_target_configuration(self) -> None:
        project = xcode_project(
            {"Debug": "YES", "Beta": "NO", "Release": "NO"},
            decoy_settings=("NO", "NO", "NO"),
        )

        with self.assertRaisesRegex(
            publisher.ReleaseError,
            r"Debug='YES'",
        ):
            publisher.require_target_build_setting(
                project,
                target_name=publisher.TARGET,
                setting="CREG_ACCESSIBILITY_HARNESS_BUILD",
                expected="NO",
                required_configurations=("Debug", "Beta", "Release"),
            )

    def test_decoy_setting_cannot_hide_a_wrong_beta_candidate(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO", "Release": "NO"})
        project["objects"]["Beta"]["buildSettings"][
            "CREG_CANDIDATE_TRAINING_RUN"
        ] = "wrong-candidate"
        project["objects"]["decoy-candidate"] = {
            "isa": "XCBuildConfiguration",
            "name": "Decoy",
            "buildSettings": {
                "CREG_CANDIDATE_TRAINING_RUN": "latest-local-v3"
            },
        }

        with self.assertRaisesRegex(
            publisher.ReleaseError, r"Beta='wrong-candidate'"
        ):
            publisher.require_target_build_setting(
                project,
                target_name=publisher.TARGET,
                setting="CREG_CANDIDATE_TRAINING_RUN",
                expected="latest-local-v3",
                required_configurations=("Beta",),
            )

    def test_rejects_a_missing_required_configuration(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO"})

        with self.assertRaisesRegex(
            publisher.ReleaseError, "missing configurations: Release"
        ):
            publisher.require_target_build_setting(
                project,
                target_name=publisher.TARGET,
                setting="CREG_ACCESSIBILITY_HARNESS_BUILD",
                expected="NO",
                required_configurations=("Debug", "Beta", "Release"),
            )

    def test_malformed_configuration_references_raise_release_errors(self) -> None:
        for location in ("configuration-list", "configuration"):
            project = xcode_project(
                {"Debug": "NO", "Beta": "NO", "Release": "NO"}
            )
            if location == "configuration-list":
                project["objects"]["target"]["buildConfigurationList"] = []
            else:
                project["objects"]["target-configurations"][
                    "buildConfigurations"
                ] = [[]]

            with (
                self.subTest(location=location),
                self.assertRaises(publisher.ReleaseError),
            ):
                publisher.target_build_configurations(project, publisher.TARGET)

    def test_decoy_build_phase_cannot_satisfy_the_target_contract(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO", "Release": "NO"})
        project["objects"]["target"]["buildPhases"] = ["target-phase"]
        project["objects"]["target-phase"] = shell_script_phase(
            "echo wrong-script", input_paths=[]
        )
        project["objects"]["decoy-phase"] = shell_script_phase(
            publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
            input_paths=["$(SRCROOT)/model-runtime-contract.json"],
        )

        with self.assertRaisesRegex(
            publisher.ReleaseError, "reviewed executable contract"
        ):
            publisher.require_target_shell_script_contract(
                project,
                target_name=publisher.TARGET,
                phase_name="Materialize Bundled SQL Model",
                expected_script=publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                input_paths=("$(SRCROOT)/model-runtime-contract.json",),
            )

    def test_inert_fragments_cannot_satisfy_the_shell_script_contract(self) -> None:
        reviewed = publisher.MATERIALIZE_MODEL_SHELL_SCRIPT
        decoys = (
            f"# {reviewed}",
            f"REVIEWED_COMMAND={reviewed!r}\n",
            f"if false; then\n  {reviewed}fi\n",
        )
        for decoy in decoys:
            project = xcode_project(
                {"Debug": "NO", "Beta": "NO", "Release": "NO"}
            )
            project["objects"]["target"]["buildPhases"] = ["target-phase"]
            project["objects"]["target-phase"] = shell_script_phase(
                decoy,
                input_paths=["$(SRCROOT)/model-runtime-contract.json"],
            )

            with (
                self.subTest(decoy=decoy),
                self.assertRaisesRegex(
                    publisher.ReleaseError, "reviewed executable contract"
                ),
            ):
                publisher.require_target_shell_script_contract(
                    project,
                    target_name=publisher.TARGET,
                    phase_name="Materialize Bundled SQL Model",
                    expected_script=reviewed,
                    input_paths=("$(SRCROOT)/model-runtime-contract.json",),
                )

    def test_shell_phase_execution_attributes_are_pinned(self) -> None:
        for attribute, _ in publisher.REVIEWED_SHELL_PHASE_ATTRIBUTES:
            project = xcode_project(
                {"Debug": "NO", "Beta": "NO", "Release": "NO"}
            )
            project["objects"]["target"]["buildPhases"] = ["target-phase"]
            phase = shell_script_phase(
                publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                input_paths=["$(SRCROOT)/model-runtime-contract.json"],
            )
            phase[attribute] = "drifted"
            project["objects"]["target-phase"] = phase

            with (
                self.subTest(attribute=attribute),
                self.assertRaisesRegex(publisher.ReleaseError, attribute),
            ):
                publisher.require_target_shell_script_contract(
                    project,
                    target_name=publisher.TARGET,
                    phase_name="Materialize Bundled SQL Model",
                    expected_script=publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                    input_paths=("$(SRCROOT)/model-runtime-contract.json",),
                )

    def test_missing_build_phase_input_paths_raise_a_missing_error(self) -> None:
        project = xcode_project({"Debug": "NO", "Beta": "NO", "Release": "NO"})
        project["objects"]["target"]["buildPhases"] = ["target-phase"]
        project["objects"]["target-phase"] = shell_script_phase(
            publisher.MATERIALIZE_MODEL_SHELL_SCRIPT
        )

        with self.assertRaisesRegex(publisher.ReleaseError, "missing input paths"):
            publisher.require_target_shell_script_contract(
                project,
                target_name=publisher.TARGET,
                phase_name="Materialize Bundled SQL Model",
                expected_script=publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                input_paths=("$(SRCROOT)/model-runtime-contract.json",),
            )

    def test_malformed_build_phase_input_paths_raise_a_targeted_error(self) -> None:
        for configured_inputs in (None, "input", [42]):
            project = xcode_project(
                {"Debug": "NO", "Beta": "NO", "Release": "NO"}
            )
            project["objects"]["target"]["buildPhases"] = ["target-phase"]
            project["objects"]["target-phase"] = shell_script_phase(
                publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                input_paths=configured_inputs,
            )

            with (
                self.subTest(configured_inputs=configured_inputs),
                self.assertRaisesRegex(
                    publisher.ReleaseError, "malformed input paths"
                ),
            ):
                publisher.require_target_shell_script_contract(
                    project,
                    target_name=publisher.TARGET,
                    phase_name="Materialize Bundled SQL Model",
                    expected_script=publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
                    input_paths=("$(SRCROOT)/model-runtime-contract.json",),
                )

    def test_repository_shell_phases_match_the_reviewed_contracts(self) -> None:
        project = publisher.load_xcode_project(REPO_ROOT)

        publisher.require_target_shell_script_contract(
            project,
            target_name=publisher.TARGET,
            phase_name="Stamp Distribution Build Number",
            expected_script=publisher.STAMP_DISTRIBUTION_BUILD_NUMBER_SHELL_SCRIPT,
        )
        publisher.require_target_shell_script_contract(
            project,
            target_name=publisher.TARGET,
            phase_name="Materialize Bundled SQL Model",
            expected_script=publisher.MATERIALIZE_MODEL_SHELL_SCRIPT,
            input_paths=("$(SRCROOT)/model-runtime-contract.json",),
        )


class CollectPreflightTests(unittest.TestCase):
    def test_rejects_beta_build_settings_that_enable_the_harness_bypass(
        self,
    ) -> None:
        xcode_version = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="Xcode 26.3\n", stderr=""
        )
        build_settings = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "CONFIGURATION = Beta\n"
                "PRODUCT_BUNDLE_IDENTIFIER = dev.haroldmartin.CREG\n"
                "DEVELOPMENT_TEAM = MGPHJKUJSY\n"
                "CODE_SIGN_STYLE = Automatic\n"
                "CREG_ACCESSIBILITY_HARNESS_BUILD = YES\n"
            ),
            stderr="",
        )
        with (
            patch.object(publisher, "verify_source_contract"),
            patch.object(
                publisher,
                "run_command",
                side_effect=[xcode_version, build_settings],
            ),
            self.assertRaisesRegex(
                publisher.ReleaseError,
                "CREG_ACCESSIBILITY_HARNESS_BUILD must be 'NO'",
            ),
        ):
            publisher.collect_preflight(
                Path("/repo"),
                tools={"xcodebuild": "xcodebuild", "uv": "uv"},
                attempt=Path("/tmp/attempt"),
                source_revision=SOURCE_REVISION,
            )


class RequireInspectorReportTests(unittest.TestCase):
    def test_rejects_missing_empty_and_non_string_build_numbers(self) -> None:
        invalid_pairs = (
            (MISSING, MISSING),
            (MISSING, "20260816093000"),
            ("", ""),
            (123, 123),
        )
        for archive_build, ipa_build in invalid_pairs:
            with (
                self.subTest(archive_build=archive_build, ipa_build=ipa_build),
                self.assertRaisesRegex(
                    publisher.ReleaseError,
                    "Artifact inspector report is missing a build number",
                ),
            ):
                publisher.require_inspector_report(
                    inspector_report(archive_build, ipa_build),
                    source_revision=SOURCE_REVISION,
                    expected_training_run="training-run",
                )

    def test_rejects_mismatched_build_numbers(self) -> None:
        with self.assertRaisesRegex(
            publisher.ReleaseError,
            "Archive and IPA build numbers do not match",
        ):
            publisher.require_inspector_report(
                inspector_report("20260816093000", "20260816093001"),
                source_revision=SOURCE_REVISION,
                expected_training_run="training-run",
            )

    def test_returns_matching_build_number(self) -> None:
        build_number = "20260816093000"

        verified = publisher.require_inspector_report(
            inspector_report(build_number, build_number),
            source_revision=SOURCE_REVISION,
            expected_training_run="training-run",
        )

        self.assertEqual(verified["build_number"], build_number)
        self.assertNotEqual(
            verified["signed_executables"]["archive"]["sha256"],
            verified["signed_executables"]["ipa"]["sha256"],
        )

    def test_rejects_archive_ipa_executable_mismatch(self) -> None:
        report = inspector_report("20260816093000", "20260816093000")
        report["artifacts"][1]["executable"]["unsigned_sha256"] = "0" * 64
        with self.assertRaisesRegex(
            publisher.ReleaseError,
            "Archive and IPA executable identities do not match",
        ):
            publisher.require_inspector_report(
                report,
                source_revision=SOURCE_REVISION,
                expected_training_run="training-run",
            )

    def test_rejects_wrong_or_dirty_source_provenance(self) -> None:
        for mutation in ("wrong-revision", "dirty"):
            report = inspector_report("20260816093000", "20260816093000")
            for artifact in report["artifacts"]:
                contract = artifact["model_runtime_contract"]
                if mutation == "wrong-revision":
                    contract["source_revision"] = "9" * 40
                else:
                    contract["source_dirty"] = True
            with (
                self.subTest(mutation=mutation),
                self.assertRaisesRegex(
                    publisher.ReleaseError,
                    "Verified artifact has invalid source provenance",
                ),
            ):
                publisher.require_inspector_report(
                    report,
                    source_revision=SOURCE_REVISION,
                    expected_training_run="training-run",
                )

    def test_rejects_invalid_code_signatures_and_wrong_candidates(self) -> None:
        report = inspector_report("20260816093000", "20260816093000")
        report["artifacts"][1]["code_signature"]["status"] = "invalid"
        with self.assertRaisesRegex(
            publisher.ReleaseError, "invalid code signature"
        ):
            publisher.require_inspector_report(
                report,
                source_revision=SOURCE_REVISION,
                expected_training_run="training-run",
            )

        report = inspector_report("20260816093000", "20260816093000")
        with self.assertRaisesRegex(
            publisher.ReleaseError, "wrong candidate training run"
        ):
            publisher.require_inspector_report(
                report,
                source_revision=SOURCE_REVISION,
                expected_training_run="different-run",
            )


class ReleaseCommandsTests(unittest.TestCase):
    def test_uses_isolated_derived_data_and_revision_based_inspection(self) -> None:
        attempt = Path("/tmp/attempt")
        commands = publisher.release_commands(
            attempt,
            {"xcodebuild": "xcodebuild", "uv": "uv"},
            "run-id",
            SOURCE_REVISION,
            "training-run",
        )

        self.assertEqual(
            commands["archive"][commands["archive"].index("-derivedDataPath") + 1],
            str(attempt / "DerivedData"),
        )
        self.assertEqual(
            commands["inspect"][
                commands["inspect"].index("--expected-training-run") + 1
            ],
            "training-run",
        )
        self.assertIn(
            "CREG_CANDIDATE_TRAINING_RUN=training-run", commands["archive"]
        )
        self.assertIn(
            "CREG_ACCESSIBILITY_HARNESS_BUILD=NO", commands["archive"]
        )
        self.assertEqual(
            commands["inspect"][
                commands["inspect"].index("--expected-source-revision") + 1
            ],
            SOURCE_REVISION,
        )


if __name__ == "__main__":
    unittest.main()
