import hashlib
import json
import plistlib
import shutil
import zipfile

import pytest

from tools.fetch_model import directory_digest, directory_inventory
from tools.inspect_release_bundle import (
    app_from_archive,
    app_from_ipa,
    verify_app,
)


TRAINING_RUN = "pinned-training-run"


def make_beta_app(tmp_path):
    app = tmp_path / "CREG.app"
    model = app / "SQLModel"
    metal = app / "mlx-swift_Cmlx.bundle"
    model.mkdir(parents=True)
    metal.mkdir()
    weights = b"verified model bytes"
    (model / "model.bin").write_bytes(weights)
    (metal / "default.metallib").write_bytes(b"metal")
    model_digest = directory_digest(directory_inventory(model))
    model_key = "debug-model"
    manifest = {
        "schema_version": 1,
        "production_status": "debug-candidate",
        "debug_candidate": {
            "model_key": model_key,
            "training_run_id": TRAINING_RUN,
        },
        "models": [
            {
                "key": model_key,
                "local_directory": model_key,
                "repository": "local-debug/pinned",
                "revision": "a" * 40,
                "snapshot_directory_sha256": model_digest,
                "required_files": [
                    {
                        "path": "model.bin",
                        "size": len(weights),
                        "sha256": hashlib.sha256(weights).hexdigest(),
                    }
                ],
                "license": {
                    "id": "apache-2.0",
                    "commercial_use": True,
                    "url": "https://example.invalid/license",
                },
            }
        ],
        "production": {
            "model_key": model_key,
            "gcd": "on",
            "temperature": 0.0,
            "top_p": 1.0,
            "top_k": 0,
            "max_tokens": 128,
            "voting": {
                "candidate_count": 3,
                "sample_temperature": 0.7,
                "always_vote": True,
            },
        },
    }
    manifest_bytes = json.dumps(manifest, sort_keys=True).encode() + b"\n"
    (app / "model-manifest.json").write_bytes(manifest_bytes)
    receipt = {
        "schema_version": 1,
        "model_key": model_key,
        "repository": "local-debug/pinned",
        "revision": "a" * 40,
        "source_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "directory_sha256": model_digest,
        "file_count": 1,
    }
    (app / "production-model-receipt.json").write_text(json.dumps(receipt))
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleIdentifier": "dev.haroldmartin.CREG",
                "CFBundleVersion": "1",
                "CREGBuildChannel": "beta",
                "CREGExperimentalTrainingRun": TRAINING_RUN,
            },
            stream,
        )
    return app


def test_beta_app_gate_verifies_model_receipt_channel_and_metal(tmp_path):
    result = verify_app(
        make_beta_app(tmp_path),
        configuration="Beta",
        expected_training_run=TRAINING_RUN,
    )
    assert result["build_channel"] == "beta"
    assert result["model"]["receipt_file_count"] == 1
    assert result["metal"]["bytes"] == 5


@pytest.mark.parametrize(
    "mutation",
    [
        "channel",
        "training_run",
        "model",
        "receipt",
        "metal_missing",
        "metal_empty",
        "metal_duplicate",
    ],
)
def test_beta_app_gate_fails_closed(tmp_path, mutation):
    app = make_beta_app(tmp_path)
    if mutation == "channel":
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CREGBuildChannel": "release",
                    "CREGExperimentalTrainingRun": TRAINING_RUN,
                },
                stream,
            )
    elif mutation == "training_run":
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CREGBuildChannel": "beta",
                    "CREGExperimentalTrainingRun": "wrong-training-run",
                },
                stream,
            )
    elif mutation == "model":
        (app / "SQLModel" / "model.bin").write_bytes(b"truncated")
    elif mutation == "receipt":
        receipt = json.loads((app / "production-model-receipt.json").read_text())
        receipt["directory_sha256"] = "0" * 64
        (app / "production-model-receipt.json").write_text(json.dumps(receipt))
    elif mutation == "metal_missing":
        (app / "mlx-swift_Cmlx.bundle" / "default.metallib").unlink()
    elif mutation == "metal_empty":
        (app / "mlx-swift_Cmlx.bundle" / "default.metallib").write_bytes(b"")
    else:
        duplicate = app / "Frameworks" / "mlx-swift_Cmlx.bundle"
        duplicate.mkdir(parents=True)
        (duplicate / "default.metallib").write_bytes(b"duplicate")

    with pytest.raises(SystemExit):
        verify_app(
            app,
            configuration="Beta",
            expected_training_run=TRAINING_RUN,
        )


def test_archive_and_ipa_resolve_the_same_app_shape(tmp_path):
    source = make_beta_app(tmp_path / "source")
    archive = tmp_path / "CREG.xcarchive"
    archive_app = archive / "Products" / "Applications" / "CREG.app"
    shutil.copytree(source, archive_app)
    assert app_from_archive(archive) == archive_app

    payload = tmp_path / "payload" / "Payload" / "CREG.app"
    shutil.copytree(source, payload)
    ipa = tmp_path / "CREG.ipa"
    with zipfile.ZipFile(ipa, "w") as bundle:
        for path in payload.parent.rglob("*"):
            if path.is_file():
                bundle.write(path, path.relative_to(payload.parent.parent))
    extracted = tmp_path / "extracted"
    extracted.mkdir()
    assert app_from_ipa(ipa, extracted).name == "CREG.app"
