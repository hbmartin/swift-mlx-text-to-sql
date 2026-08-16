#!/usr/bin/env python3
"""Prepare, verify, and upload CREG's internal-only TestFlight build."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

PROJECT = "CREG.xcodeproj"
SCHEME = "CREG"
TARGET = "CREG"
CONFIGURATION = "Beta"
BUNDLE_IDENTIFIER = "dev.haroldmartin.CREG"
DEVELOPMENT_TEAM = "MGPHJKUJSY"
BUILD_CHANNEL = "beta"
OUTPUT_ROOT = Path("build/testflight")
TRAINING_RUNS = Path("eval/training-runs")
MODEL_MANIFEST = Path("model-manifest.json")
MODEL_RUNTIME_CONTRACT = Path("model-runtime-contract.json")
INSPECTOR = Path("fine-tuning/tools/inspect_release_bundle.py")
SCHEME_FILE = Path("CREG.xcodeproj/xcshareddata/xcschemes/CREG.xcscheme")
INFO_PLIST = Path("CREG/Info.plist")
PROJECT_FILE = Path("CREG.xcodeproj/project.pbxproj")
SECRET_KEY_PATTERN = re.compile(
    r"(?i)(password|passwd|token|secret|authorization|api[_-]?key|private[_-]?key)"
)
SECRET_ASSIGNMENT_PATTERN = re.compile(
    r"(?i)\b(password|passwd|token|secret|authorization|api[_-]?key|private[_-]?key)"
    r"(\s*[:=]\s*)(\S+)"
)
BEARER_PATTERN = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+")
PRIVATE_KEY_PATTERN = re.compile(
    r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
    re.DOTALL,
)


class ReleaseError(RuntimeError):
    """Stop the release without continuing to a later publishing phase."""


def default_repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def sanitize_text(value: str) -> str:
    value = PRIVATE_KEY_PATTERN.sub("[REDACTED PRIVATE KEY]", value)
    value = BEARER_PATTERN.sub(r"\1[REDACTED]", value)
    return SECRET_ASSIGNMENT_PATTERN.sub(r"\1\2[REDACTED]", value)


def command_text(command: Sequence[str]) -> str:
    safe_parts = []
    redact_next = False
    for part in command:
        if redact_next:
            safe_parts.append("[REDACTED]")
            redact_next = False
            continue
        if SECRET_KEY_PATTERN.search(part):
            if "=" in part:
                key = part.split("=", 1)[0]
                safe_parts.append(f"{key}=[REDACTED]")
            else:
                safe_parts.append(part)
                redact_next = part.startswith("-")
            continue
        safe_parts.append(part)
    return shlex.join(safe_parts)


def run_command(
    command: Sequence[str],
    *,
    cwd: Path,
    log_path: Path | None = None,
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        list(command),
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        check=False,
    )
    stdout = sanitize_text(completed.stdout)
    stderr = sanitize_text(completed.stderr)
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(
            f"$ {command_text(command)}\n\n"
            f"--- stdout ---\n{stdout}\n"
            f"--- stderr ---\n{stderr}\n"
            f"--- exit code ---\n{completed.returncode}\n"
        )
    sanitized = subprocess.CompletedProcess(
        args=completed.args,
        returncode=completed.returncode,
        stdout=stdout,
        stderr=stderr,
    )
    if completed.returncode != 0 and not allow_failure:
        details = "\n".join(part for part in (stdout.strip(), stderr.strip()) if part)
        if details:
            print(details, file=sys.stderr)
        location = f" See {log_path}." if log_path is not None else ""
        raise ReleaseError(
            f"Command failed with exit code {completed.returncode}: "
            f"{command_text(command)}.{location}"
        )
    return sanitized


def require_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise ReleaseError(f"Missing {description}: {path}")


def require_directory(path: Path, description: str) -> None:
    if not path.is_dir():
        raise ReleaseError(f"Missing {description}: {path}")


def discover_tool(name: str) -> str:
    result = shutil.which(name)
    if result is None and name == "uv":
        fallback = Path.home() / ".local/bin/uv"
        if fallback.is_file() and os.access(fallback, os.X_OK):
            result = str(fallback)
    if result is None:
        raise ReleaseError(f"Required tool is not available: {name}")
    return str(Path(result).resolve())


def git_value(git: str, repo: Path, *args: str) -> str:
    return run_command([git, *args], cwd=repo).stdout.strip()


def git_identity(git: str, repo: Path) -> dict[str, str]:
    top_level = Path(git_value(git, repo, "rev-parse", "--show-toplevel")).resolve()
    if top_level != repo:
        raise ReleaseError(f"Expected Git root {repo}, found {top_level}")
    branch = git_value(git, repo, "rev-parse", "--abbrev-ref", "HEAD")
    return {
        "commit": git_value(git, repo, "rev-parse", "HEAD"),
        "branch": branch if branch != "HEAD" else "(detached)",
    }


def require_ignored_output(git: str, repo: Path) -> None:
    probe = OUTPUT_ROOT / ".release-state-probe"
    result = run_command(
        [git, "check-ignore", "--quiet", str(probe)],
        cwd=repo,
        allow_failure=True,
    )
    if result.returncode != 0:
        raise ReleaseError(
            f"Release output path must be ignored by Git before use: {OUTPUT_ROOT}"
        )


def require_clean_git(git: str, repo: Path) -> None:
    status = run_command(
        [
            git,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignore-submodules=none",
        ],
        cwd=repo,
    ).stdout.rstrip("\r\n")
    if status:
        lines = status.splitlines()
        visible = lines[:40]
        print("\n".join(visible), file=sys.stderr)
        if len(lines) > len(visible):
            print(
                f"... {len(lines) - len(visible)} additional dirty paths omitted",
                file=sys.stderr,
            )
        raise ReleaseError(
            "TestFlight preparation requires a clean Git worktree. Commit, "
            "remove, or stash every tracked and untracked change first."
        )


def create_attempt_directory(repo: Path) -> tuple[str, Path]:
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"beta-{timestamp}-{uuid.uuid4().hex[:8]}"
    attempt = repo / OUTPUT_ROOT / run_id
    attempt.mkdir(parents=True, exist_ok=False)
    return run_id, attempt


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    staged = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        staged.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        staged.replace(path)
    finally:
        if staged.exists():
            staged.unlink()


def load_json(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"Expected an object in {description}: {path}")
    return value


def require_object(
    container: dict[str, Any], key: str, description: str
) -> dict[str, Any]:
    value = container.get(key)
    if not isinstance(value, dict):
        raise ReleaseError(f"{description} must be an object")
    return value


def archive_configuration(scheme_path: Path) -> str:
    try:
        root = ET.parse(scheme_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise ReleaseError(f"Cannot parse shared scheme {scheme_path}: {error}") from error
    action = root.find("ArchiveAction")
    if action is None:
        raise ReleaseError(f"Shared scheme has no ArchiveAction: {scheme_path}")
    return action.attrib.get("buildConfiguration", "")


def parse_build_settings(output: str) -> dict[str, str]:
    settings: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$", line)
        if match:
            settings[match.group(1)] = match.group(2).strip()
    return settings


def require_setting(
    settings: dict[str, str], key: str, expected: str | None = None
) -> str:
    value = settings.get(key, "")
    if not value:
        raise ReleaseError(f"Beta build setting {key} is missing")
    if expected is not None and value != expected:
        raise ReleaseError(
            f"Beta build setting {key} must be {expected!r}, found {value!r}"
        )
    return value


def resolve_repo_path(repo: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (repo / path).resolve()


def verify_model_inputs(repo: Path, training_run: str) -> dict[str, str]:
    models = repo / "models"
    adapters = models / "adapters"
    fused = models / "debug-fused"
    training_directory = repo / TRAINING_RUNS / training_run
    require_directory(models, "local model cache")
    require_directory(adapters, "adapter cache")
    require_directory(fused, "fused-model cache")
    require_directory(training_directory, "pinned Beta training run")

    training_manifest_path = training_directory / "manifest.json"
    require_file(training_manifest_path, "pinned training manifest")
    training_manifest = load_json(training_manifest_path, "training manifest")
    if training_manifest.get("run_id") != training_run:
        raise ReleaseError(
            "Pinned training directory and manifest run_id disagree: "
            f"{training_run!r} vs {training_manifest.get('run_id')!r}"
        )

    outputs = require_object(training_manifest, "outputs", "Training manifest outputs")
    checkpoint_evaluation = require_object(
        training_manifest,
        "checkpoint_evaluation",
        "Training manifest checkpoint_evaluation",
    )
    selected = require_object(
        checkpoint_evaluation,
        "selected",
        "Training manifest checkpoint_evaluation.selected",
    )
    experiment = require_object(
        training_manifest, "experiment", "Training manifest experiment"
    )
    adapter_value = outputs.get("adapter")
    checkpoint_value = selected.get("checkpoint_path")
    model_key = experiment.get("model_key")
    identity_values = (adapter_value, checkpoint_value, model_key)
    if not all(isinstance(value, str) and value for value in identity_values):
        raise ReleaseError(
            "Pinned training manifest must name its adapter directory, selected "
            "checkpoint, and experiment.model_key"
        )
    adapter_directory = resolve_repo_path(repo, adapter_value)
    checkpoint = resolve_repo_path(repo, checkpoint_value)
    require_directory(adapter_directory, "pinned adapter directory")
    require_file(checkpoint, "selected adapter checkpoint")
    if checkpoint.parent != adapter_directory:
        raise ReleaseError("Selected adapter checkpoint is outside its adapter directory")

    source_manifest_path = repo / MODEL_MANIFEST
    source_manifest = load_json(source_manifest_path, "model manifest")
    artifacts = source_manifest.get("models")
    if not isinstance(artifacts, list):
        raise ReleaseError("model-manifest.json must declare models")
    artifact = next(
        (
            item
            for item in artifacts
            if isinstance(item, dict) and item.get("key") == model_key
        ),
        None,
    )
    if artifact is None or artifact.get("derived"):
        raise ReleaseError(f"Pinned training run references unsupported base {model_key!r}")
    conversion = artifact.get("conversion")
    local_directory = (
        conversion.get("output_directory")
        if isinstance(conversion, dict)
        else artifact.get("local_directory")
    )
    if not isinstance(local_directory, str) or not local_directory:
        raise ReleaseError(f"Base model {model_key!r} has no local cache directory")
    base_model = models / local_directory
    require_directory(base_model, "manifest-pinned base model")

    return {
        "training_run_directory": str(training_directory),
        "adapter_directory": str(adapter_directory),
        "checkpoint": str(checkpoint),
        "base_model_key": model_key,
        "base_model_directory": str(base_model),
        "fused_cache": str(fused),
    }


def verify_candidate_inputs(repo: Path, selector: str) -> dict[str, str]:
    if selector != "latest-local-v3":
        return verify_model_inputs(repo, selector)
    models = repo / "models"
    adapters = models / "adapters"
    fused = models / "debug-fused"
    training_runs = repo / TRAINING_RUNS
    require_directory(models, "local model cache")
    require_directory(adapters, "adapter cache")
    require_directory(fused, "fused-model cache")
    require_directory(training_runs, "local training runs")
    if not any(path.is_dir() for path in training_runs.iterdir()):
        raise ReleaseError("latest-local-v3 requires at least one local training run")
    return {
        "candidate_selector": selector,
        "training_runs": str(training_runs),
        "adapter_cache": str(adapters),
        "fused_cache": str(fused),
    }


def verify_source_contract(repo: Path) -> None:
    scheme_path = repo / SCHEME_FILE
    require_file(scheme_path, "shared CREG scheme")
    configuration = archive_configuration(scheme_path)
    if configuration != CONFIGURATION:
        raise ReleaseError(
            f"CREG ArchiveAction must use {CONFIGURATION}, found {configuration!r}"
        )

    info_path = repo / INFO_PLIST
    require_file(info_path, "source Info.plist")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReleaseError(f"Cannot parse {info_path}: {error}") from error
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        raise ReleaseError("ITSAppUsesNonExemptEncryption must be false for CREG")

    project_text = (repo / PROJECT_FILE).read_text()
    required_fragments = (
        "Stamp Distribution Build Number",
        "date -u +%Y%m%d%H%M%S",
        "CREG_BUILD_CHANNEL = beta;",
        'CREG_CANDIDATE_TRAINING_RUN = "latest-local-v3";',
        "model-runtime-contract.json",
        "materialize_bundled_model.sh",
    )
    missing = [fragment for fragment in required_fragments if fragment not in project_text]
    if missing:
        raise ReleaseError(
            "Xcode project is missing required Beta release settings: "
            + ", ".join(missing)
        )


def collect_preflight(
    repo: Path,
    *,
    tools: dict[str, str],
    attempt: Path,
    source_revision: str,
) -> dict[str, Any]:
    verify_source_contract(repo)
    xcode_version = run_command(
        [tools["xcodebuild"], "-version"],
        cwd=repo,
        log_path=attempt / "logs/xcode-version.log",
    ).stdout.strip()
    settings_result = run_command(
        [
            tools["xcodebuild"],
            "-project",
            PROJECT,
            "-target",
            TARGET,
            "-configuration",
            CONFIGURATION,
            "-showBuildSettings",
        ],
        cwd=repo,
        log_path=attempt / "logs/build-settings.log",
    )
    settings = parse_build_settings(settings_result.stdout)
    require_setting(settings, "CONFIGURATION", CONFIGURATION)
    require_setting(settings, "PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_IDENTIFIER)
    require_setting(settings, "DEVELOPMENT_TEAM", DEVELOPMENT_TEAM)
    require_setting(settings, "CODE_SIGN_STYLE", "Automatic")
    require_setting(settings, "CREG_BUILD_CHANNEL", BUILD_CHANNEL)
    candidate_selector = settings.get("CREG_CANDIDATE_TRAINING_RUN", "").strip()
    marketing_version = require_setting(settings, "MARKETING_VERSION")
    source_build_number = require_setting(settings, "CURRENT_PROJECT_VERSION")
    model_inputs = (
        verify_candidate_inputs(repo, candidate_selector)
        if candidate_selector
        else {"selection": "verified-production"}
    )
    uv_version = run_command(
        [tools["uv"], "--version"],
        cwd=repo,
        log_path=attempt / "logs/uv-version.log",
    ).stdout.strip()
    return {
        "configuration": CONFIGURATION,
        "scheme": SCHEME,
        "target": TARGET,
        "bundle_identifier": BUNDLE_IDENTIFIER,
        "development_team": DEVELOPMENT_TEAM,
        "code_sign_style": "Automatic",
        "build_channel": BUILD_CHANNEL,
        "marketing_version": marketing_version,
        "source_build_number": source_build_number,
        "build_number": None,
        "candidate_selector": candidate_selector,
        "source_revision": source_revision,
        "xcode_version": xcode_version,
        "uv_version": uv_version,
        "model_inputs": model_inputs,
    }


def export_options(destination: str) -> dict[str, Any]:
    return {
        "destination": destination,
        "distributionBundleIdentifier": BUNDLE_IDENTIFIER,
        "manageAppVersionAndBuildNumber": False,
        "method": "app-store-connect",
        "signingStyle": "automatic",
        "stripSwiftSymbols": True,
        "teamID": DEVELOPMENT_TEAM,
        "testFlightInternalTestingOnly": True,
        "uploadSymbols": True,
    }


def write_plist(path: Path, value: dict[str, Any]) -> None:
    with path.open("wb") as stream:
        plistlib.dump(value, stream, sort_keys=True)


def release_commands(
    attempt: Path,
    tools: dict[str, str],
    run_id: str,
    source_revision: str,
) -> dict[str, list[str]]:
    archive = attempt / "CREG-beta.xcarchive"
    export = attempt / "beta-export"
    upload_export = attempt / "upload-export"
    export_plist = attempt / "ExportOptions-export.plist"
    upload_plist = attempt / "ExportOptions-upload.plist"
    verification = attempt / "verification"
    derived_data = attempt / "DerivedData"
    return {
        "archive": [
            tools["xcodebuild"],
            "-project",
            PROJECT,
            "-scheme",
            SCHEME,
            "-configuration",
            CONFIGURATION,
            "-destination",
            "generic/platform=iOS",
            "-skipPackagePluginValidation",
            "-skipMacroValidation",
            "-archivePath",
            str(archive),
            "-derivedDataPath",
            str(derived_data),
            "-allowProvisioningUpdates",
            "archive",
        ],
        "export": [
            tools["xcodebuild"],
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportPath",
            str(export),
            "-exportOptionsPlist",
            str(export_plist),
            "-allowProvisioningUpdates",
        ],
        "inspect": [
            tools["uv"],
            "run",
            "--frozen",
            "python",
            "tools/inspect_release_bundle.py",
            "--configuration",
            CONFIGURATION,
            "--run-id",
            run_id,
            "--expected-source-revision",
            source_revision,
            "--archive",
            str(archive),
            "--ipa",
            str(export / "CREG.ipa"),
            "--reports-dir",
            str(verification),
        ],
        "upload": [
            tools["xcodebuild"],
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportPath",
            str(upload_export),
            "-exportOptionsPlist",
            str(upload_plist),
            "-allowProvisioningUpdates",
        ],
    }


def archive_info(archive: Path) -> dict[str, str]:
    applications = archive / "Products/Applications"
    apps = sorted(applications.glob("*.app"))
    if len(apps) != 1:
        raise ReleaseError(f"Archive must contain exactly one app: {archive}")
    info_path = apps[0] / "Info.plist"
    require_file(info_path, "archived app Info.plist")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReleaseError(f"Cannot parse archived Info.plist: {error}") from error
    bundle = str(info.get("CFBundleIdentifier", ""))
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if bundle != BUNDLE_IDENTIFIER:
        raise ReleaseError(f"Archived bundle identifier is unexpected: {bundle!r}")
    if not version:
        raise ReleaseError("Archived marketing version is missing")
    if not re.fullmatch(r"\d{14}", build):
        raise ReleaseError(
            "Archived build number must be the UTC YYYYMMDDHHMMSS stamp, "
            f"found {build!r}"
        )
    return {
        "app": str(apps[0]),
        "bundle_identifier": bundle,
        "marketing_version": version,
        "build_number": build,
    }


def sole_ipa(export_directory: Path) -> Path:
    candidates = sorted(export_directory.rglob("*.ipa"))
    if len(candidates) != 1:
        raise ReleaseError(
            f"Expected exactly one exported IPA under {export_directory}, "
            f"found {len(candidates)}"
        )
    return candidates[0]


def parse_json_output(output: str, description: str) -> dict[str, Any]:
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise ReleaseError(f"{description} did not emit valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"{description} must emit a JSON object")
    return value


def require_inspector_report(
    report: dict[str, Any], *, source_revision: str
) -> dict[str, Any]:
    if (
        report.get("schema_version") != 3
        or report.get("status") != "complete"
        or report.get("configuration") != CONFIGURATION
    ):
        raise ReleaseError("Artifact inspector did not emit a complete Beta schema-v3 report")
    artifacts = report.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 2:
        raise ReleaseError("Artifact inspector must report exactly archive and IPA artifacts")
    by_kind = {
        item.get("artifact_kind"): item for item in artifacts if isinstance(item, dict)
    }
    if set(by_kind) != {"archive", "ipa"}:
        raise ReleaseError("Artifact inspector report must contain archive and IPA")
    archive = by_kind["archive"]
    ipa = by_kind["ipa"]
    identity_keys = (
        "bundle_identifier",
        "marketing_version",
        "build_number",
        "build_channel",
        "model_runtime_contract",
        "production",
        "debug_candidate",
        "model",
        "executable",
        "metal",
        "inputs",
    )
    for artifact in (archive, ipa):
        if artifact.get("bundle_identifier") != BUNDLE_IDENTIFIER:
            raise ReleaseError("Verified artifact has an unexpected bundle identifier")
        if artifact.get("build_channel") != BUILD_CHANNEL:
            raise ReleaseError("Verified artifact is not a Beta build")
        build_number = artifact.get("build_number")
        if not isinstance(build_number, str) or not build_number:
            raise ReleaseError("Artifact inspector report is missing a build number")
        contract = artifact.get("model_runtime_contract")
        if contract != {
            "version": 1,
            "source_revision": source_revision,
            "source_dirty": False,
        }:
            raise ReleaseError("Verified artifact has invalid source provenance")
        executable = artifact.get("executable")
        if not isinstance(executable, dict) or not executable.get("sha256"):
            raise ReleaseError("Artifact inspector report is missing executable verification")
        model = artifact.get("model")
        if not isinstance(model, dict):
            raise ReleaseError("Artifact inspector report is missing model verification")
        if model.get("verified_directory_sha256") != model.get(
            "expected_directory_sha256"
        ):
            raise ReleaseError("Verified model digest does not match the expected digest")
        if not model.get("receipt_directory_sha256"):
            raise ReleaseError("Verified model receipt digest is missing")
        inputs = artifact.get("inputs")
        if not isinstance(inputs, dict) or any(
            re.fullmatch(r"[0-9a-f]{64}", str(inputs.get(key, ""))) is None
            for key in ("bundled_manifest_sha256", "production_receipt_sha256")
        ):
            raise ReleaseError("Artifact inspector report is missing input hashes")
        metal = artifact.get("metal")
        if not isinstance(metal, dict) or not metal.get("sha256"):
            raise ReleaseError("Artifact inspector report is missing Metal verification")
    if archive.get("build_number") != ipa.get("build_number"):
        raise ReleaseError("Archive and IPA build numbers do not match")
    mismatched = [key for key in identity_keys if archive.get(key) != ipa.get(key)]
    if mismatched:
        raise ReleaseError(
            "Archive and IPA verification disagree: " + ", ".join(mismatched)
        )
    archive_model = archive["model"]
    if archive_model.get("verified_directory_sha256") != archive_model.get(
        "expected_directory_sha256"
    ):
        raise ReleaseError("Verified model digest does not match the expected digest")
    return {
        "build_number": archive["build_number"],
        "model_runtime_contract": archive["model_runtime_contract"],
        "debug_candidate": archive.get("debug_candidate"),
        "production": archive["production"],
        "model": archive_model,
        "executable": archive["executable"],
        "metal": archive.get("metal"),
        "inputs": archive["inputs"],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=default_repo_root(),
        help=argparse.SUPPRESS,
    )
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("preflight", "publish"):
        subparser = subparsers.add_parser(operation)
        subparser.add_argument(
            "--dry-run",
            action="store_true",
            help="validate and emit the planned commands without building or uploading",
        )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = args.repo_root.expanduser().resolve()
    required_files = (
        (repo / MODEL_MANIFEST, "model manifest"),
        (repo / MODEL_RUNTIME_CONTRACT, "model runtime contract"),
        (repo / INSPECTOR, "release-bundle inspector"),
        (repo / PROJECT_FILE, "Xcode project file"),
    )
    try:
        require_directory(repo / PROJECT, "CREG Xcode project")
        for path, description in required_files:
            require_file(path, description)
        tools = {
            "git": discover_tool("git"),
            "xcodebuild": discover_tool("xcodebuild"),
            "uv": discover_tool("uv"),
        }
        git = git_identity(tools["git"], repo)
        require_ignored_output(tools["git"], repo)
        run_id, attempt = create_attempt_directory(repo)
    except (OSError, ReleaseError) as error:
        print(f"error: {sanitize_text(str(error))}", file=sys.stderr)
        return 1

    release_path = attempt / "release.json"
    state: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "operation": args.operation,
        "dry_run": bool(args.dry_run),
        "status": "preflight_started",
        "created_at": datetime.now(UTC).isoformat(),
        "repository": str(repo),
        "git": git,
        "attempt_directory": str(attempt),
        "logs": str(attempt / "logs"),
        "completion_boundary": "app_store_connect_ready_to_test",
    }
    try:
        atomic_write_json(release_path, state)
        require_clean_git(tools["git"], repo)
        state["preflight"] = collect_preflight(
            repo,
            tools=tools,
            attempt=attempt,
            source_revision=git["commit"],
        )
        state["status"] = "preflight_passed"
        atomic_write_json(release_path, state)
        if args.operation == "preflight":
            if args.dry_run:
                state["status"] = "preflight_dry_run_complete"
            state["completed_at"] = datetime.now(UTC).isoformat()
            atomic_write_json(release_path, state)
            print(json.dumps(state, indent=2, sort_keys=True))
            print(f"Release state: {release_path}")
            return 0

        write_plist(attempt / "ExportOptions-export.plist", export_options("export"))
        write_plist(attempt / "ExportOptions-upload.plist", export_options("upload"))
        commands = release_commands(
            attempt,
            tools,
            run_id,
            state["preflight"]["source_revision"],
        )
        state["commands"] = {
            key: command_text(value) for key, value in commands.items()
        }
        state["artifacts"] = {
            "archive": str(attempt / "CREG-beta.xcarchive"),
            "export_directory": str(attempt / "beta-export"),
            "export_options": str(attempt / "ExportOptions-export.plist"),
            "upload_options": str(attempt / "ExportOptions-upload.plist"),
        }
        if args.dry_run:
            state["status"] = "publish_dry_run_complete"
            state["completed_at"] = datetime.now(UTC).isoformat()
            atomic_write_json(release_path, state)
            print(json.dumps(state, indent=2, sort_keys=True))
            print(f"Release state: {release_path}")
            return 0

        run_command(
            commands["archive"],
            cwd=repo,
            log_path=attempt / "logs/archive.log",
        )
        archived = archive_info(attempt / "CREG-beta.xcarchive")
        if archived["marketing_version"] != state["preflight"]["marketing_version"]:
            raise ReleaseError("Archived marketing version changed after preflight")
        state["preflight"]["build_number"] = archived["build_number"]
        state["artifacts"]["archived_app"] = archived["app"]
        state["status"] = "archive_complete"
        atomic_write_json(release_path, state)

        run_command(
            commands["export"],
            cwd=repo,
            log_path=attempt / "logs/export.log",
        )
        ipa = sole_ipa(attempt / "beta-export")
        state["artifacts"]["ipa"] = str(ipa)
        state["status"] = "export_complete"
        atomic_write_json(release_path, state)

        expected_ipa = str(attempt / "beta-export/CREG.ipa")
        commands["inspect"][commands["inspect"].index(expected_ipa)] = str(ipa)
        state["commands"]["inspect"] = command_text(commands["inspect"])
        inspection = run_command(
            commands["inspect"],
            cwd=repo / "fine-tuning",
            log_path=attempt / "logs/inspect.log",
        )
        inspector_report = parse_json_output(inspection.stdout, "Artifact inspector")
        verified = require_inspector_report(
            inspector_report,
            source_revision=state["preflight"]["source_revision"],
        )
        if verified["build_number"] != archived["build_number"]:
            raise ReleaseError("Inspector and archive build numbers do not match")
        state["verification"] = verified
        state["verification"]["report"] = str(
            attempt / "verification" / run_id / "report.json"
        )
        state["status"] = "artifacts_verified"
        atomic_write_json(release_path, state)

        run_command(
            commands["upload"],
            cwd=repo,
            log_path=attempt / "logs/upload.log",
        )
        state["upload"] = {
            "status": "accepted",
            "accepted_at": datetime.now(UTC).isoformat(),
            "internal_only": True,
        }
        state["app_store_connect"] = {
            "status": "verification_required",
            "expected_bundle_identifier": BUNDLE_IDENTIFIER,
            "expected_marketing_version": archived["marketing_version"],
            "expected_build_number": archived["build_number"],
            "success_statuses": ["Ready to Test", "Testing"],
            "terminal_failure_statuses": ["Invalid Binary", "Rejected"],
        }
        state["status"] = "upload_accepted_awaiting_app_store_connect"
        atomic_write_json(release_path, state)
        print(json.dumps(state, indent=2, sort_keys=True))
        print(f"Release state: {release_path}")
        return 0
    except (OSError, ReleaseError) as error:
        state["status"] = "failed"
        state["failed_at"] = datetime.now(UTC).isoformat()
        state["error"] = sanitize_text(str(error))
        atomic_write_json(release_path, state)
        print(f"error: {state['error']}", file=sys.stderr)
        print(f"Release state: {release_path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
