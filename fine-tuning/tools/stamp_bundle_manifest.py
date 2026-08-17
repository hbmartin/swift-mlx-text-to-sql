"""Stamp a bundled model manifest with its executable compatibility contract."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


def load_object(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{description} must contain a JSON object: {path}")
    return value


def stamp_manifest(
    source: Path,
    contract_path: Path,
    *,
    source_revision: str,
    source_dirty: bool,
) -> dict[str, Any]:
    if re.fullmatch(r"[0-9a-f]{40}", source_revision) is None:
        raise SystemExit("source revision must be a lowercase 40-character Git SHA")
    contract = load_object(contract_path, "model runtime contract")
    version = contract.get("current_version")
    if contract.get("schema_version") != 1 or not isinstance(version, int) or version < 1:
        raise SystemExit(
            "model runtime contract requires schema_version 1 and a positive current_version"
        )
    manifest = load_object(source, "source model manifest")
    manifest["model_runtime_contract"] = {
        "version": version,
        "source_revision": source_revision,
        "source_dirty": source_dirty,
    }
    return manifest


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(
                json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
                + b"\n"
            )
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument(
        "--source-dirty", choices=("true", "false"), required=True
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest = stamp_manifest(
        args.source.resolve(),
        args.contract.resolve(),
        source_revision=args.source_revision,
        source_dirty=args.source_dirty == "true",
    )
    atomic_write_json(args.destination.resolve(), manifest)


if __name__ == "__main__":
    main()
