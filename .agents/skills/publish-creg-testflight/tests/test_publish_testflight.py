from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "publish_testflight.py"
MISSING = object()


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
            "build_channel": publisher.BUILD_CHANNEL,
            "debug_candidate": {"training_run_id": "training-run"},
            "model": model.copy(),
            "metal": {"verified": True},
        }
        if build_number is not MISSING:
            value["build_number"] = build_number
        return value

    return {
        "schema_version": 2,
        "status": "complete",
        "configuration": publisher.CONFIGURATION,
        "artifacts": [
            artifact("archive", archive_build),
            artifact("ipa", ipa_build),
        ],
    }


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
                    training_run="training-run",
                )

    def test_rejects_mismatched_build_numbers(self) -> None:
        with self.assertRaisesRegex(
            publisher.ReleaseError,
            "Archive and IPA build numbers do not match",
        ):
            publisher.require_inspector_report(
                inspector_report("20260816093000", "20260816093001"),
                training_run="training-run",
            )

    def test_returns_matching_build_number(self) -> None:
        build_number = "20260816093000"

        verified = publisher.require_inspector_report(
            inspector_report(build_number, build_number),
            training_run="training-run",
        )

        self.assertEqual(verified["build_number"], build_number)


if __name__ == "__main__":
    unittest.main()
