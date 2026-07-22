"""Immutable evaluation-run directory and provenance helpers."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import platform
import shlex
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from eval.file_integrity import sha256_file as integrity_sha256_file

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNS_DIR = REPO_ROOT / "eval" / "runs"


class RunArtifactError(RuntimeError):
    pass


class DirtyWorktreeError(RunArtifactError):
    def __init__(self) -> None:
        super().__init__("immutable experiment evidence requires a clean Git worktree")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return integrity_sha256_file(path)


def slug(value: str) -> str:
    cleaned = "".join(c.lower() if c.isalnum() else "-" for c in value)
    return "-".join(part for part in cleaned.split("-") if part)


def default_run_id(
    model_key: str, gold: Path, gcd: str, temperature: float, seed: int
) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return (
        f"{stamp}-{slug(model_key)}-{slug(gold.stem)}-gcd-{gcd}"
        f"-t-{str(temperature).replace('.', '_')}-s-{seed}"
    )


def create_run_directory(root: Path, run_id: str) -> Path:
    directory = root / run_id
    try:
        directory.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise RunArtifactError(
            f"run directory already exists and will not be overwritten: {directory}"
        ) from error
    return directory


def command_line() -> str:
    return shlex.join([sys.executable, *sys.argv])


def git_value(*args: str) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def git_provenance() -> dict[str, Any]:
    try:
        return {
            "commit": git_value("rev-parse", "HEAD"),
            "branch": git_value("branch", "--show-current"),
            "dirty": bool(git_value("status", "--porcelain")),
        }
    except (OSError, subprocess.CalledProcessError) as error:
        # A null commit in an immutable manifest would defeat the point of
        # recording provenance; fail the run instead.
        raise RunArtifactError(
            "git provenance is required for immutable evidence; run inside "
            "the repository with git available"
        ) from error


def clean_git_provenance() -> dict[str, Any]:
    provenance = git_provenance()
    if provenance["dirty"]:
        raise DirtyWorktreeError
    return provenance


def dependency_versions() -> dict[str, str | None]:
    packages = ["mlx", "mlx-lm", "numpy", "transformers", "xgrammar"]
    versions: dict[str, str | None] = {}
    for package in packages:
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    versions["sqlite"] = sqlite3.sqlite_version
    return versions


def hardware_provenance() -> dict[str, Any]:
    def sysctl(name: str) -> str | None:
        try:
            return subprocess.run(
                ["sysctl", "-n", name],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    def command_output(*command: str) -> str | None:
        try:
            return subprocess.run(
                command, check=True, capture_output=True, text=True
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None

    return {
        "platform": platform.platform(),
        "os_version": command_output("sw_vers"),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": sys.version,
        "model": sysctl("hw.model"),
        "physical_memory_bytes": (
            int(value) if (value := sysctl("hw.memsize")) is not None else None
        ),
        "cpu_count": os.cpu_count(),
        "swift": command_output("swift", "--version"),
    }


def input_hash(path: Path) -> dict[str, Any]:
    absolute = path.absolute()
    try:
        display_path = absolute.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        display_path = str(absolute)
    digest = sha256_file(absolute)
    return {
        "path": display_path,
        "size": absolute.lstat().st_size,
        "sha256": digest,
    }


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def percentile(values: list[int], percentile_value: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = round((len(ordered) - 1) * percentile_value)
    return ordered[index]
