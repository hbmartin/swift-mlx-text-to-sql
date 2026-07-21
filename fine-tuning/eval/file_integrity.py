"""Dependency-light, fail-closed filesystem integrity primitives.

Every recursive consumer uses the same no-follow walk. Entries are classified
with ``lstat`` before exclusions are applied, so a symlink or special file can
never disappear behind a cache/filter rule.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any


class IntegrityError(RuntimeError):
    """A tree cannot be safely inventoried or transactionally replaced."""


def _reject_symlinked_ancestors(path: Path) -> None:
    """Reject a regular-looking entry reached through a linked directory."""
    current = path.absolute().parent
    while True:
        try:
            metadata = current.lstat()
        except OSError as error:
            raise IntegrityError(
                f"cannot inspect ancestor {current}: {error}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise IntegrityError(
                f"symbolic links are not allowed in path ancestors: {current}"
            )
        parent = current.parent
        if parent == current:
            return
        current = parent


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()


def _require_regular_file(path: Path) -> os.stat_result:
    _reject_symlinked_ancestors(path)
    try:
        metadata = path.lstat()
    except OSError as error:
        raise IntegrityError(f"cannot inspect regular file {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise IntegrityError(f"symbolic links are not allowed: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        raise IntegrityError(f"non-regular filesystem entry is not allowed: {path}")
    return metadata


def sha256_file(path: Path) -> str:
    """Hash a regular file without following symbolic links."""
    _require_regular_file(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise IntegrityError(f"cannot open regular file {path}: {error}") from error
    digest = hashlib.sha256()
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise IntegrityError(
                f"filesystem entry changed while being inspected: {path}"
            )
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def regular_files(
    directory: Path,
    *,
    include: Callable[[Path], bool] | None = None,
) -> list[Path]:
    """Return regular files after rejecting all links and special entries.

    ``include`` is evaluated only after entry classification. Directories are
    always traversed, which prevents exclusions from hiding unsafe content.
    """
    _reject_symlinked_ancestors(directory)
    try:
        root_metadata = directory.lstat()
    except OSError as error:
        raise IntegrityError(f"cannot inspect directory {directory}: {error}") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise IntegrityError(f"expected a real directory, found {directory}")

    selected: list[Path] = []

    def visit(current: Path) -> None:
        try:
            entries = sorted(os.scandir(current), key=lambda entry: entry.name)
        except OSError as error:
            raise IntegrityError(f"cannot scan directory {current}: {error}") from error
        for entry in entries:
            path = Path(entry.path)
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise IntegrityError(f"cannot inspect entry {path}: {error}") from error
            mode = metadata.st_mode
            if stat.S_ISLNK(mode):
                raise IntegrityError(f"symbolic links are not allowed: {path}")
            if stat.S_ISDIR(mode):
                visit(path)
            elif stat.S_ISREG(mode):
                relative = path.relative_to(directory)
                if include is None or include(relative):
                    selected.append(path)
            else:
                raise IntegrityError(
                    f"non-regular filesystem entry is not allowed: {path}"
                )

    visit(directory)
    return sorted(
        selected,
        key=lambda path: path.relative_to(directory).as_posix(),
    )


def directory_inventory(
    directory: Path,
    *,
    include: Callable[[Path], bool] | None = None,
) -> list[dict[str, Any]]:
    return [
        {
            "path": path.relative_to(directory).as_posix(),
            "size": path.lstat().st_size,
            "sha256": sha256_file(path),
        }
        for path in regular_files(directory, include=include)
    ]


def directory_digest(inventory: list[dict[str, Any]]) -> str:
    return hashlib.sha256(canonical_json(inventory)).hexdigest()


def transactionally_replace_directory(staged: Path, destination: Path) -> None:
    """Atomically install a verified sibling tree with rollback on failure."""
    _reject_symlinked_ancestors(staged)
    _reject_symlinked_ancestors(destination)
    if staged.parent != destination.parent:
        raise IntegrityError(
            f"staged and destination directories must be siblings: {staged}, {destination}"
        )
    if staged.is_symlink() or not staged.is_dir():
        raise IntegrityError(f"staged tree is not a real directory: {staged}")
    if destination.is_symlink():
        raise IntegrityError(f"destination is a symbolic link: {destination}")

    backup = destination.parent / (
        f".{destination.name}.backup-{uuid.uuid4().hex}"
    )
    had_destination = destination.exists()
    if had_destination:
        destination.rename(backup)
    try:
        staged.rename(destination)
    except BaseException:
        if had_destination and backup.exists() and not destination.exists():
            backup.rename(destination)
        raise
    if had_destination:
        shutil.rmtree(backup)
