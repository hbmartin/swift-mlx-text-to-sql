"""Shared, dependency-free text-to-SQL prompt contract."""

from __future__ import annotations

import hashlib
import re
import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCE_DIRECTORY = REPO_ROOT / "CREGKit" / "Sources" / "CREGEngine" / "Resources"
SYSTEM_PROMPT_TEMPLATE_PATH = RESOURCE_DIRECTORY / "system_prompt_template.txt"
REPAIR_PROMPT_TEMPLATE_PATH = RESOURCE_DIRECTORY / "repair_prompt_template.txt"
SCHEMA_CATALOG_PATH = RESOURCE_DIRECTORY / "schema_catalog.json"
PROMPT_VERSION = "reliability-v2"
POLICY_VERSION = "bounded-three-generation-v1"


def _template(path: Path) -> str:
    return path.read_text().rstrip("\r\n")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prompt_contract_receipt(schema: str | None = None) -> dict[str, Any]:
    """Return the immutable prompt/catalog identity recorded by every run."""

    catalog = json.loads(SCHEMA_CATALOG_PATH.read_text())
    receipt: dict[str, Any] = {
        "prompt_version": PROMPT_VERSION,
        "policy_version": POLICY_VERSION,
        "system_template_sha256": _sha256(SYSTEM_PROMPT_TEMPLATE_PATH),
        "repair_template_sha256": _sha256(REPAIR_PROMPT_TEMPLATE_PATH),
        "schema_catalog_sha256": _sha256(SCHEMA_CATALOG_PATH),
        "schema_catalog_version": catalog["schema_version"],
    }
    if schema is not None:
        receipt["rendered_system_prompt_sha256"] = hashlib.sha256(
            build_system_prompt(schema).encode()
        ).hexdigest()
    return receipt


def build_system_prompt(schema: str) -> str:
    return _template(SYSTEM_PROMPT_TEMPLATE_PATH).replace("{{SCHEMA}}", schema)


def build_repair_prompt(
    *,
    question: str,
    failed_sql: str,
    sqlite_error: str,
    issue_type: str,
    issue_disposition: str,
    declared_sources: list[str] | tuple[str, ...] = (),
    possible_column_owners: list[str] | tuple[str, ...] = (),
    failed_fingerprints: list[str] | tuple[str, ...] = (),
) -> str:
    replacements = {
        "{{QUESTION}}": question,
        "{{FAILED_SQL}}": failed_sql,
        "{{SQLITE_ERROR}}": sqlite_error,
        "{{ISSUE_TYPE}}": issue_type,
        "{{ISSUE_DISPOSITION}}": issue_disposition,
        "{{DECLARED_SOURCES}}": ", ".join(declared_sources),
        "{{POSSIBLE_COLUMN_OWNERS}}": ", ".join(possible_column_owners),
        "{{FAILED_FINGERPRINTS}}": ", ".join(failed_fingerprints),
    }
    return re.sub(
        r"\{\{[A-Z_]+\}\}",
        lambda match: replacements.get(match.group(0), match.group(0)),
        _template(REPAIR_PROMPT_TEMPLATE_PATH),
    )
