from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "publish_testflight.py"
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
            "executable": {"sha256": "c" * 64, "bytes": 10},
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
                )

    def test_rejects_mismatched_build_numbers(self) -> None:
        with self.assertRaisesRegex(
            publisher.ReleaseError,
            "Archive and IPA build numbers do not match",
        ):
            publisher.require_inspector_report(
                inspector_report("20260816093000", "20260816093001"),
                source_revision=SOURCE_REVISION,
            )

    def test_returns_matching_build_number(self) -> None:
        build_number = "20260816093000"

        verified = publisher.require_inspector_report(
            inspector_report(build_number, build_number),
            source_revision=SOURCE_REVISION,
        )

        self.assertEqual(verified["build_number"], build_number)

    def test_rejects_archive_ipa_executable_mismatch(self) -> None:
        report = inspector_report("20260816093000", "20260816093000")
        report["artifacts"][1]["executable"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(
            publisher.ReleaseError,
            "Archive and IPA verification disagree: executable",
        ):
            publisher.require_inspector_report(
                report, source_revision=SOURCE_REVISION
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
                    report, source_revision=SOURCE_REVISION
                )


class ReleaseCommandsTests(unittest.TestCase):
    def test_uses_isolated_derived_data_and_revision_based_inspection(self) -> None:
        attempt = Path("/tmp/attempt")
        commands = publisher.release_commands(
            attempt,
            {"xcodebuild": "xcodebuild", "uv": "uv"},
            "run-id",
            SOURCE_REVISION,
        )

        self.assertEqual(
            commands["archive"][commands["archive"].index("-derivedDataPath") + 1],
            str(attempt / "DerivedData"),
        )
        self.assertNotIn("--expected-training-run", commands["inspect"])
        self.assertEqual(
            commands["inspect"][
                commands["inspect"].index("--expected-source-revision") + 1
            ],
            SOURCE_REVISION,
        )


if __name__ == "__main__":
    unittest.main()
