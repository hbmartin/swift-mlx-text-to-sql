import json

import pytest

from tools.stamp_bundle_manifest import stamp_manifest


def test_manifest_stamp_is_canonical_for_candidate_and_production_inputs(tmp_path):
    contract = tmp_path / "model-runtime-contract.json"
    contract.write_text('{"schema_version":1,"current_version":1}\n')
    revision = "a" * 40
    for status in ("verified", "debug-candidate"):
        source = tmp_path / f"{status}.json"
        source.write_text(json.dumps({"schema_version": 1, "production_status": status}))

        stamped = stamp_manifest(
            source,
            contract,
            source_revision=revision,
            source_dirty=False,
        )

        assert stamped["model_runtime_contract"] == {
            "version": 1,
            "source_revision": revision,
            "source_dirty": False,
        }


@pytest.mark.parametrize("revision", ["a" * 39, "A" * 40, "not-a-git-sha"])
def test_manifest_stamp_rejects_invalid_source_revisions(tmp_path, revision):
    source = tmp_path / "manifest.json"
    source.write_text("{}\n")
    contract = tmp_path / "contract.json"
    contract.write_text('{"schema_version":1,"current_version":1}\n')

    with pytest.raises(SystemExit, match="lowercase 40-character Git SHA"):
        stamp_manifest(
            source,
            contract,
            source_revision=revision,
            source_dirty=False,
        )
