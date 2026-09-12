from __future__ import annotations

import json
from pathlib import Path

from tools import check_swift_package_pins


REVISION = "a" * 40


def write_fixture(root: Path, *, package_revision: str = REVISION) -> None:
    manifest = root / check_swift_package_pins.MANIFEST
    manifest.parent.mkdir(parents=True)
    manifest.write_text(
        """
        .package(
          url: "https://github.com/hbmartin/AutoTableCharts.git",
          revision: "%s")
        """
        % REVISION
    )
    for relative_path in check_swift_package_pins.RESOLUTIONS:
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "pins": [
                        {
                            "identity": "autotablecharts",
                            "state": {"revision": package_revision},
                        }
                    ]
                }
            )
        )


def test_checked_in_autotablecharts_pins_agree() -> None:
    assert check_swift_package_pins.pin_failures() == []


def test_pin_check_reports_a_resolution_that_drifted(tmp_path: Path) -> None:
    write_fixture(tmp_path, package_revision="b" * 40)

    failures = check_swift_package_pins.pin_failures(tmp_path)

    assert len(failures) == 2
    assert all("AutoTableCharts resolves to" in failure for failure in failures)


def test_pin_check_accepts_matching_resolutions(tmp_path: Path) -> None:
    write_fixture(tmp_path)

    assert check_swift_package_pins.pin_failures(tmp_path) == []
