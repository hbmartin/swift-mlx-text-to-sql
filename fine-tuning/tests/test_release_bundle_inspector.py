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
SOURCE_REVISION = "b" * 40


def make_beta_app(tmp_path):
    app = tmp_path / "CREG.app"
    model = app / "SQLModel"
    metal = app / "mlx-swift_Cmlx.bundle"
    model.mkdir(parents=True)
    metal.mkdir()
    weights = b"verified model bytes"
    (model / "model.bin").write_bytes(weights)
    (metal / "default.metallib").write_bytes(b"metal")
    (app / "CREG").write_bytes(b"executable")
    model_digest = directory_digest(directory_inventory(model))
    model_key = "debug-model"
    manifest = {
        "schema_version": 1,
        "production_status": "debug-candidate",
        "debug_candidate": {
            "model_key": model_key,
            "base_model_key": "base-model",
            "training_run_id": TRAINING_RUN,
            "selected_iteration": 600,
            "selected_checkpoint_sha256": "a" * 64,
            "local_evidence_status": "complete",
            "wandb_receipt_required": False,
        },
        "model_runtime_contract": {
            "version": 1,
            "source_revision": SOURCE_REVISION,
            "source_dirty": False,
        },
        "models": [
            {
                "key": model_key,
                "local_directory": model_key,
                "repository": "local-debug/pinned",
                "revision": "a" * 40,
                "training_run": TRAINING_RUN,
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
                "CFBundleExecutable": "CREG",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "CREGBuildChannel": "beta",
                "CREGModelRuntimeContractVersion": 1,
                "CREGSourceRevision": SOURCE_REVISION,
                "CREGSourceDirty": False,
            },
            stream,
        )
    return app


def test_beta_app_gate_verifies_model_receipt_channel_and_metal(tmp_path):
    result = verify_app(
        make_beta_app(tmp_path),
        configuration="Beta",
        expected_source_revision=SOURCE_REVISION,
    )
    assert result["build_channel"] == "beta"
    assert result["model"]["receipt_file_count"] == 1
    assert result["metal"]["bytes"] == 5
    assert result["executable"]["sha256"]
    assert result["model_runtime_contract"]["source_revision"] == SOURCE_REVISION


@pytest.mark.parametrize("configuration", ["Debug", "Beta"])
@pytest.mark.parametrize("status", ["debug-candidate", "verified"])
def test_debug_and_beta_accept_the_same_model_states(tmp_path, configuration, status):
    app = make_beta_app(tmp_path)
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    info["CREGBuildChannel"] = configuration.lower()
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    if status == "verified":
        manifest_path = app / "model-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["production_status"] = "verified"
        manifest["debug_candidate"] = None
        manifest_bytes = json.dumps(manifest, sort_keys=True).encode() + b"\n"
        manifest_path.write_bytes(manifest_bytes)
        receipt_path = app / "production-model-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["source_manifest_sha256"] = hashlib.sha256(manifest_bytes).hexdigest()
        receipt_path.write_text(json.dumps(receipt))

    result = verify_app(
        app,
        configuration=configuration,
        expected_source_revision=SOURCE_REVISION,
    )
    if status == "verified":
        assert result["debug_candidate"] is None
    else:
        assert isinstance(result["debug_candidate"], dict)


@pytest.mark.parametrize(
    "mutation",
    [
        "channel",
        "missing_contract",
        "wrong_contract",
        "wrong_revision",
        "dirty_source",
        "executable_missing",
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
                    "CREGModelRuntimeContractVersion": 1,
                    "CREGSourceRevision": SOURCE_REVISION,
                    "CREGSourceDirty": False,
                },
                stream,
            )
    elif mutation == "missing_contract":
        manifest = json.loads((app / "model-manifest.json").read_text())
        manifest.pop("model_runtime_contract")
        (app / "model-manifest.json").write_text(json.dumps(manifest))
    elif mutation == "wrong_contract":
        manifest = json.loads((app / "model-manifest.json").read_text())
        manifest["model_runtime_contract"]["version"] = 2
        (app / "model-manifest.json").write_text(json.dumps(manifest))
    elif mutation == "wrong_revision":
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        info["CREGSourceRevision"] = "c" * 40
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
    elif mutation == "dirty_source":
        manifest = json.loads((app / "model-manifest.json").read_text())
        manifest["model_runtime_contract"]["source_dirty"] = True
        (app / "model-manifest.json").write_text(json.dumps(manifest))
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        info["CREGSourceDirty"] = True
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
    elif mutation == "executable_missing":
        (app / "CREG").unlink()
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
            expected_source_revision=SOURCE_REVISION,
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
